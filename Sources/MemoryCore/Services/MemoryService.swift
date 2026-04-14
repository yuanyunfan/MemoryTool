import CryptoKit
import Foundation
import GRDB

/// Service layer providing all memory data operations.
///
/// Thread-safe: backed by GRDB's serialized database access.
/// All write operations run inside transactions.
public final class MemoryService: Sendable {
    let db: AppDatabase
    private let embeddingService: EmbeddingService?

    public init(database: AppDatabase, embeddingService: EmbeddingService? = nil) {
        self.db = database
        self.embeddingService = embeddingService
    }

    // MARK: - Deduplication

    /// Result of a deduplication check.
    public enum DeduplicationResult: Sendable {
        /// No duplicate found — safe to create.
        case noDuplicate
        /// Similar content found (similarity score).
        case similarExists(existingId: String, similarity: Float)
    }

    /// Check if content is semantically similar to existing memories.
    ///
    /// Uses cosine similarity > 0.85 threshold to detect paraphrases
    /// (e.g. "我爱吃火锅" vs "用户爱吃火锅").
    public func checkDuplicate(content: String) throws -> DeduplicationResult {
        guard let embeddingService, let queryVec = embeddingService.embed(content, isQuery: false) else {
            return .noDuplicate
        }

        let candidates = try loadEmbeddings()
        let results = EmbeddingService.search(
            query: queryVec,
            candidates: candidates,
            topK: 1,
            threshold: 0.85
        )
        if let top = results.first {
            return .similarExists(existingId: top.id, similarity: top.similarity)
        }

        return .noDuplicate
    }

    // MARK: - CRUD

    /// Creates a new memory with semantic deduplication.
    ///
    /// If a semantically similar memory exists (cosine > 0.85),
    /// updates the existing memory instead of creating a duplicate.
    @discardableResult
    public func createMemory(
        content: String,
        category: String = "general",
        source: String? = nil,
        tags: [String]? = nil,
        metadata: String? = nil
    ) throws -> Memory {
        // Generate embedding
        let embeddingData = embeddingService?.embed(content, isQuery: false)
            .map { EmbeddingService.encodeEmbedding($0) }

        let memory = Memory(
            content: content,
            category: category,
            source: source,
            metadata: metadata,
            contentHash: Self.generateContentHash(content),
            accessCount: 0,
            lastAccessedAt: nil,
            embedding: embeddingData
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
        let result: Memory? = try db.writer().write { dbConn -> Memory? in
            guard var memory = try Memory.fetchOne(dbConn, key: id) else {
                return nil
            }

            if let content {
                memory.content = content
                memory.contentHash = Self.generateContentHash(content)
                // Regenerate embedding for updated content
                memory.embedding = embeddingService?.embed(content, isQuery: false)
                    .map { EmbeddingService.encodeEmbedding($0) }
            }
            if let category { memory.category = category }
            if let source { memory.source = source }
            if let metadata { memory.metadata = metadata }
            memory.updatedAt = Date()

            try memory.update(dbConn)
            return memory
        }
        return result
    }

    /// Deletes a memory by ID. Returns true if a record was actually deleted.
    /// Also cleans up orphaned tags that are no longer associated with any memory.
    @discardableResult
    public func deleteMemory(id: String) throws -> Bool {
        try db.writer().write { dbConn in
            guard let memory = try Memory.fetchOne(dbConn, key: id) else {
                return false
            }
            try memory.delete(dbConn)

            // Clean up orphaned tags (tags with no remaining memory associations)
            try dbConn.execute(sql: """
                DELETE FROM tag
                WHERE id NOT IN (SELECT DISTINCT tag_id FROM memory_tag)
                """)

            return true
        }
    }

    // MARK: - Access Tracking (Ranking Weights)

    /// Record an access to a memory, incrementing access_count and updating last_accessed_at.
    public func recordAccess(id: String) throws {
        try db.writer().write { dbConn in
            try dbConn.execute(
                sql: """
                    UPDATE memory
                    SET access_count = access_count + 1,
                        last_accessed_at = ?
                    WHERE id = ?
                    """,
                arguments: [Date(), id]
            )
        }
    }

    /// Record access for multiple memories at once.
    public func recordAccess(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.writer().write { dbConn in
            for id in ids {
                try dbConn.execute(
                    sql: """
                        UPDATE memory
                        SET access_count = access_count + 1,
                            last_accessed_at = ?
                        WHERE id = ?
                        """,
                    arguments: [Date(), id]
                )
            }
        }
    }

    // MARK: - Search (Hybrid: FTS5 + Semantic + Ranking)

    /// Hybrid search combining keyword (FTS5), semantic (embedding), and ranking weights.
    ///
    /// Scoring formula:
    ///   `final_score = w_keyword * keyword_score + w_semantic * semantic_score + w_recency * recency_score + w_frequency * frequency_score`
    ///
    /// Where:
    ///   - keyword_score: FTS5 rank normalized to [0, 1]
    ///   - semantic_score: cosine similarity [0, 1]
    ///   - recency_score: exponential decay based on age (half-life = 30 days)
    ///   - frequency_score: log(1 + access_count) / log(1 + max_access_count)
    public func searchMemories(
        query: String,
        category: String? = nil,
        tags: [String]? = nil,
        limit: Int = 20
    ) throws -> [Memory] {
        let effectiveLimit = min(max(limit, 1), 100)
        let terms = extractSearchTerms(query)

        // If no query, fall back to listing
        guard !terms.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return try listMemories(category: category, limit: effectiveLimit, offset: 0)
        }

        // Phase 1: Keyword search (FTS5 + LIKE)
        let keywordResults = try keywordSearch(
            terms: terms,
            category: category,
            tags: tags,
            limit: effectiveLimit * 3 // Fetch more for re-ranking
        )

        // Phase 2: Semantic search (if embedding available)
        var semanticScores: [String: Float] = [:]
        if let embeddingService, let queryVec = embeddingService.embed(query) {
            let candidates = try loadEmbeddings(category: category, tags: tags)
            let semanticResults = EmbeddingService.search(
                query: queryVec,
                candidates: candidates,
                topK: effectiveLimit * 3,
                threshold: 0.3
            )
            for result in semanticResults {
                semanticScores[result.id] = result.similarity
            }
        }

        // Phase 3: Merge and rank
        let allIds = Set(keywordResults.map(\.memory.id))
            .union(Set(semanticScores.keys))

        // Load full memories for semantic-only results
        var memoriesById: [String: Memory] = [:]
        for kr in keywordResults {
            memoriesById[kr.memory.id] = kr.memory
        }
        for id in semanticScores.keys where memoriesById[id] == nil {
            if let memory = try getMemory(id: id) {
                memoriesById[id] = memory
            }
        }

        // Build keyword score map (normalize FTS5 rank to [0, 1])
        var keywordScores: [String: Float] = [:]
        if !keywordResults.isEmpty {
            let minRank = keywordResults.map(\.rank).min() ?? 0
            let maxRank = keywordResults.map(\.rank).max() ?? 0
            let range = maxRank - minRank
            for kr in keywordResults {
                // FTS5 rank is negative (more negative = better match)
                // Normalize so best match = 1.0
                if range > 0 {
                    keywordScores[kr.memory.id] = Float(1.0 - (kr.rank - minRank) / range)
                } else {
                    keywordScores[kr.memory.id] = 1.0
                }
            }
        }

        // Compute max access count for frequency normalization
        let maxAccessCount = memoriesById.values.map(\.accessCount).max() ?? 1

        // Score and rank all candidates
        var scored: [(memory: Memory, score: Float)] = []
        for id in allIds {
            guard let memory = memoriesById[id] else { continue }

            let kScore = keywordScores[id] ?? 0.0
            let sScore = semanticScores[id] ?? 0.0

            // Recency score: exponential decay, half-life = 30 days
            let ageInDays = Float(-memory.createdAt.timeIntervalSinceNow / 86400.0)
            let recencyScore = exp(-0.693 * ageInDays / 30.0) // ln(2)/30 ≈ 0.0231

            // Frequency score: log-normalized access count
            let freqScore: Float
            if maxAccessCount > 0 {
                freqScore = log(1.0 + Float(memory.accessCount)) / log(1.0 + Float(maxAccessCount))
            } else {
                freqScore = 0.0
            }

            // Weighted combination
            let hasKeyword = kScore > 0
            let hasSemantic = sScore > 0

            let finalScore: Float
            if hasKeyword && hasSemantic {
                // Both signals available — balanced weights
                finalScore = 0.35 * kScore + 0.35 * sScore + 0.15 * recencyScore + 0.15 * freqScore
            } else if hasKeyword {
                // Keyword only — give it more weight
                finalScore = 0.55 * kScore + 0.25 * recencyScore + 0.20 * freqScore
            } else {
                // Semantic only
                finalScore = 0.55 * sScore + 0.25 * recencyScore + 0.20 * freqScore
            }

            scored.append((memory: memory, score: finalScore))
        }

        scored.sort { $0.score > $1.score }

        let results = Array(scored.prefix(effectiveLimit).map(\.memory))

        // Record access for returned results
        try? recordAccess(ids: results.map(\.id))

        return results
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

    // MARK: - Keyword Search (internal)

    private struct KeywordResult {
        let memory: Memory
        let rank: Double
    }

    private func keywordSearch(
        terms: [String],
        category: String?,
        tags: [String]?,
        limit: Int
    ) throws -> [KeywordResult] {
        guard !terms.isEmpty else { return [] }

        let ftsTerms = terms.filter { $0.count >= 3 }
        let likeTerms = terms.filter { $0.count < 3 }

        return try db.reader().read { dbConn in
            var unionParts: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if !ftsTerms.isEmpty {
                let ftsQuery = ftsTerms.joined(separator: " OR ")
                unionParts.append("""
                    SELECT memory.*, memory_fts.rank AS search_rank
                    FROM memory
                    INNER JOIN memory_fts ON memory_fts.rowid = memory.rowid
                        AND memory_fts MATCH ?
                    """)
                arguments.append(ftsQuery)
            }

            for term in likeTerms {
                // Compute a synthetic negative rank for LIKE results to approximate
                // FTS5 ranking behavior. Uses occurrence frequency (via LENGTH trick)
                // and early-position bonus so that LIKE-only queries (common with
                // short CJK terms like '猫') still produce meaningful ranking.
                //
                // Formula: -(occurrences * 10.0 + position_bonus)
                //   occurrences = (LENGTH(content) - LENGTH(REPLACE(content, term, ''))) / LENGTH(term)
                //   position_bonus = 5.0 * (1.0 - CAST(MIN(INSTR(content, term), LENGTH(content)) AS REAL) / MAX(LENGTH(content), 1))
                //
                // The result is negative (like FTS5 rank), with more negative = better match.
                unionParts.append("""
                    SELECT memory.*,
                        -(
                            CAST((LENGTH(content) - LENGTH(REPLACE(content, ?, ''))) AS REAL) / MAX(LENGTH(?), 1) * 10.0
                            + 5.0 * (1.0 - CAST(MIN(INSTR(content, ?), LENGTH(content)) AS REAL) / MAX(LENGTH(content), 1))
                        ) AS search_rank
                    FROM memory
                    WHERE memory.content LIKE ? ESCAPE '\\'
                    """)
                let escapedTerm = term
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                // Arguments: raw term for REPLACE, raw term for LENGTH, raw term for INSTR, escaped for LIKE
                arguments.append(term)
                arguments.append(term)
                arguments.append(term)
                arguments.append("%\(escapedTerm)%")
            }

            let innerSQL = unionParts.joined(separator: " UNION ALL ")
            var sql = """
                SELECT id, content, category, source, created_at, updated_at, metadata,
                       content_hash, access_count, last_accessed_at, embedding,
                       MIN(search_rank) AS best_rank
                FROM (\(innerSQL))
                WHERE 1=1
                """

            if let category {
                sql += " AND category = ?"
                arguments.append(category)
            }

            if let tags, !tags.isEmpty {
                let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
                sql += """
                     AND id IN (
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

            sql += " GROUP BY id ORDER BY best_rank LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(
                dbConn,
                sql: sql,
                arguments: StatementArguments(arguments)
            )

            return rows.compactMap { row -> KeywordResult? in
                guard let memory = try? Memory(row: row) else { return nil }
                let rank: Double = row["best_rank"] ?? 0.0
                return KeywordResult(memory: memory, rank: rank)
            }
        }
    }

    // MARK: - Embedding Helpers

    /// Load all embeddings from database for vector search.
    private func loadEmbeddings(
        category: String? = nil,
        tags: [String]? = nil
    ) throws -> [(id: String, embedding: [Float])] {
        try db.reader().read { dbConn in
            var sql = "SELECT id, embedding FROM memory WHERE embedding IS NOT NULL"
            var arguments: [any DatabaseValueConvertible] = []

            if let category {
                sql += " AND category = ?"
                arguments.append(category)
            }

            if let tags, !tags.isEmpty {
                let placeholders = tags.map { _ in "?" }.joined(separator: ", ")
                sql += """
                     AND id IN (
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

            let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row -> (id: String, embedding: [Float])? in
                guard let id: String = row["id"],
                      let data: Data = row["embedding"]
                else { return nil }
                return (id: id, embedding: EmbeddingService.decodeEmbedding(data))
            }
        }
    }

    // MARK: - Tags

    /// Adds tags to a memory. Creates tags that don't exist yet.
    public func addTags(to memoryId: String, tags: [String]) throws {
        guard !tags.isEmpty else { return }

        try db.writer().write { dbConn in
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

    /// Returns categories with their memory counts, using a single GROUP BY query.
    public func listCategoriesWithCounts() throws -> [(category: String, count: Int)] {
        try db.reader().read { dbConn in
            let rows = try Row.fetchAll(
                dbConn,
                sql: "SELECT category, COUNT(*) AS cnt FROM memory GROUP BY category ORDER BY category"
            )
            return rows.map { row in
                (category: row["category"] as String, count: row["cnt"] as Int)
            }
        }
    }

    // MARK: - Stats

    /// Returns the total number of memories.
    public func totalMemoryCount() throws -> Int {
        try db.reader().read { dbConn in
            try Memory.fetchCount(dbConn)
        }
    }

    // MARK: - Embedding Management

    /// Generate and store embeddings for all memories that don't have one yet.
    public func backfillEmbeddings() throws -> Int {
        guard let embeddingService else { return 0 }

        let memories = try db.reader().read { dbConn in
            try Memory.filter(Column("embedding") == nil).fetchAll(dbConn)
        }

        var count = 0
        for memory in memories {
            if let vector = embeddingService.embed(memory.content, isQuery: false) {
                let data = EmbeddingService.encodeEmbedding(vector)
                try db.writer().write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE memory SET embedding = ? WHERE id = ?",
                        arguments: [data, memory.id]
                    )
                }
                count += 1
            }
        }
        return count
    }

    // MARK: - Private Helpers

    /// Generates a SHA256 content hash from the given content string.
    ///
    /// Normalizes the content (trim whitespace + lowercase) before hashing,
    /// matching the approach used by the v3 migration backfill.
    static func generateContentHash(_ content: String) -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Insert tags and create join records. Must be called inside a write transaction.
    private func insertTags(_ tags: [String], for memoryId: String, in dbConn: Database) throws {
        for tagName in tags {
            let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let tag: Tag
            if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(dbConn) {
                tag = existing
            } else {
                var newTag = Tag(name: trimmed)
                try newTag.insert(dbConn)
                tag = newTag
            }

            guard let tagId = tag.id else { continue }

            let exists = try MemoryTag
                .filter(Column("memory_id") == memoryId && Column("tag_id") == tagId)
                .fetchOne(dbConn)

            if exists == nil {
                let join = MemoryTag(memoryId: memoryId, tagId: tagId)
                try join.insert(dbConn)
            }
        }
    }

    /// Extract and sanitize individual search terms from a raw query string.
    private func extractSearchTerms(_ query: String) -> [String] {
        let ftsOperators = ["AND", "OR", "NOT", "NEAR"]
        var result = query

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

        let specialChars: Set<Character> = ["*", "\"", "(", ")", "{", "}", "^", ":", "+", "-", "~"]
        result = String(result.filter { !specialChars.contains($0) })

        return result.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }
}
