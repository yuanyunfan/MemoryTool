import Foundation
import GRDB

/// Service layer providing all memory data operations.
///
/// Thread-safe: backed by GRDB's serialized database access.
/// All write operations run inside transactions.
public final class MemoryService: Sendable {
    let db: AppDatabase

    public init(database: AppDatabase) {
        self.db = database
    }

    // MARK: - CRUD

    /// Creates a new memory, optionally with tags.
    @discardableResult
    public func createMemory(
        content: String,
        category: String = "general",
        source: String? = nil,
        tags: [String]? = nil,
        metadata: String? = nil
    ) throws -> Memory {
        let memory = Memory(
            content: content,
            category: category,
            source: source,
            metadata: metadata
        )

        try db.writer().write { dbConn in
            try memory.insert(dbConn)

            if let tags, !tags.isEmpty {
                try self.insertTags(tags, for: memory.id, in: dbConn)
            }
        }

        return memory
    }

    /// Fetches a single memory by ID.
    public func getMemory(id: String) throws -> Memory? {
        try db.reader().read { dbConn in
            try Memory.fetchOne(dbConn, key: id)
        }
    }

    /// Updates an existing memory. Returns the updated memory, or nil if not found.
    @discardableResult
    public func updateMemory(
        id: String,
        content: String? = nil,
        category: String? = nil,
        source: String? = nil,
        metadata: String? = nil
    ) throws -> Memory? {
        try db.writer().write { dbConn in
            guard var memory = try Memory.fetchOne(dbConn, key: id) else {
                return nil
            }

            if let content { memory.content = content }
            if let category { memory.category = category }
            if let source { memory.source = source }
            if let metadata { memory.metadata = metadata }
            memory.updatedAt = Date()

            try memory.update(dbConn)
            return memory
        }
    }

    /// Deletes a memory by ID. Returns true if a record was actually deleted.
    @discardableResult
    public func deleteMemory(id: String) throws -> Bool {
        try db.writer().write { dbConn in
            guard let memory = try Memory.fetchOne(dbConn, key: id) else {
                return false
            }
            try memory.delete(dbConn)
            return true
        }
    }

    // MARK: - Search

    /// Full-text search using FTS5. Falls back to listing if query is empty.
    public func searchMemories(
        query: String,
        category: String? = nil,
        tags: [String]? = nil,
        limit: Int = 20
    ) throws -> [Memory] {
        let effectiveLimit = min(max(limit, 1), 100)
        let sanitized = sanitizeFTSQuery(query)

        // If query is empty after sanitization, fall back to list
        guard !sanitized.isEmpty else {
            return try listMemories(category: category, limit: effectiveLimit, offset: 0)
        }

        return try db.reader().read { dbConn in
            var sql = """
                SELECT memory.*
                FROM memory
                INNER JOIN memory_fts ON memory_fts.rowid = memory.rowid
                    AND memory_fts MATCH ?
                """
            var arguments: [any DatabaseValueConvertible] = [sanitized]

            if let category {
                sql += " AND memory.category = ?"
                arguments.append(category)
            }

            if let tags, !tags.isEmpty {
                let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
                sql += """
                     AND memory.id IN (
                        SELECT mt.memory_id FROM memory_tag mt
                        INNER JOIN tag t ON t.id = mt.tag_id
                        WHERE t.name IN (\(placeholders))
                        GROUP BY mt.memory_id
                        HAVING COUNT(DISTINCT t.name) = ?
                    )
                    """
                for tag in tags { arguments.append(tag) }
                arguments.append(tags.count)
            }

            sql += " ORDER BY rank LIMIT ?"
            arguments.append(effectiveLimit)

            return try Memory.fetchAll(
                dbConn,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Lists memories with optional category filter and pagination.
    public func listMemories(
        category: String? = nil,
        limit: Int = 20,
        offset: Int = 0
    ) throws -> [Memory] {
        let effectiveLimit = min(max(limit, 1), 100)

        return try db.reader().read { dbConn in
            var request = Memory.order(Column("created_at").desc)

            if let category {
                request = request.filter(Column("category") == category)
            }

            return try request
                .limit(effectiveLimit, offset: offset)
                .fetchAll(dbConn)
        }
    }

    // MARK: - Tags

    /// Adds tags to a memory. Creates tags that don't exist yet.
    public func addTags(to memoryId: String, tags: [String]) throws {
        guard !tags.isEmpty else { return }

        try db.writer().write { dbConn in
            // Verify memory exists
            guard try Memory.fetchOne(dbConn, key: memoryId) != nil else {
                return
            }
            try self.insertTags(tags, for: memoryId, in: dbConn)
        }
    }

    /// Removes specific tags from a memory.
    public func removeTags(from memoryId: String, tags: [String]) throws {
        guard !tags.isEmpty else { return }

        try db.writer().write { dbConn in
            let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
            var arguments: [any DatabaseValueConvertible] = [memoryId]
            for tag in tags { arguments.append(tag) }

            try dbConn.execute(
                sql: """
                    DELETE FROM memory_tag
                    WHERE memory_id = ?
                      AND tag_id IN (
                        SELECT id FROM tag WHERE name IN (\(placeholders))
                      )
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Returns all tags associated with a memory.
    public func getTagsForMemory(id: String) throws -> [Tag] {
        try db.reader().read { dbConn in
            try Tag.fetchAll(
                dbConn,
                sql: """
                    SELECT t.* FROM tag t
                    INNER JOIN memory_tag mt ON mt.tag_id = t.id
                    WHERE mt.memory_id = ?
                    ORDER BY t.name
                    """,
                arguments: [id]
            )
        }
    }

    /// Returns all tags in the database.
    public func listAllTags() throws -> [Tag] {
        try db.reader().read { dbConn in
            try Tag.order(Column("name")).fetchAll(dbConn)
        }
    }

    // MARK: - Categories

    /// Returns a sorted list of distinct categories.
    public func listCategories() throws -> [String] {
        try db.reader().read { dbConn in
            try String.fetchAll(
                dbConn,
                sql: "SELECT DISTINCT category FROM memory ORDER BY category"
            )
        }
    }

    // MARK: - Stats

    /// Returns the total number of memories.
    public func totalMemoryCount() throws -> Int {
        try db.reader().read { dbConn in
            try Memory.fetchCount(dbConn)
        }
    }

    // MARK: - Private Helpers

    /// Insert tags and create join records. Must be called inside a write transaction.
    private func insertTags(_ tags: [String], for memoryId: String, in dbConn: Database) throws {
        for tagName in tags {
            let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Find or create tag
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(dbConn) {
                tag = existing
            } else {
                var newTag = Tag(name: trimmed)
                try newTag.insert(dbConn)
                tag = newTag
            }

            guard let tagId = tag.id else { continue }

            // Insert join record if not already present
            let exists = try MemoryTag
                .filter(Column("memory_id") == memoryId && Column("tag_id") == tagId)
                .fetchOne(dbConn)

            if exists == nil {
                let join = MemoryTag(memoryId: memoryId, tagId: tagId)
                try join.insert(dbConn)
            }
        }
    }

    /// Sanitize a search query by removing FTS5 special operators.
    private func sanitizeFTSQuery(_ query: String) -> String {
        let ftsOperators = ["AND", "OR", "NOT", "NEAR"]
        var result = query

        // Remove FTS5 operators (case-insensitive whole words)
        for op in ftsOperators {
            let pattern = "\\b\(op)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        // Remove special FTS5 characters
        let specialChars: Set<Character> = ["*", "\"", "(", ")", "{", "}", "^", ":", "+"]
        result = String(result.filter { !specialChars.contains($0) })

        // Collapse whitespace and trim
        let components = result.split(separator: " ").map(String.init)
        return components.joined(separator: " ")
    }
}
