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

        let results = try batchedEmbeddingSearch(
            query: queryVec,
            topK: 1,
            threshold: 0.85
        )
        if let top = results.first {
            return .similarExists(existingId: top.id, similarity: top.similarity)
        }

        return .noDuplicate
    }

    /// Check if content is semantically similar to existing memories (async version).
    ///
    /// Uses cosine similarity > 0.85 threshold to detect paraphrases.
    /// Prefer this over the sync version when calling from async contexts.
    public func checkDuplicateAsync(content: String) async throws -> DeduplicationResult {
        guard let embeddingService else { return .noDuplicate }
        guard let queryVec = await embeddingService.embedAsync(content, isQuery: false) else {
            return .noDuplicate
        }

        let results = try batchedEmbeddingSearch(
            query: queryVec,
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
        // Semantic deduplication: if a similar memory exists, update it instead
        let dupResult = try checkDuplicate(content: content)
        if case .similarExists(let existingId, _) = dupResult {
            if let updated = try updateMemory(id: existingId, content: content, category: category, source: source, metadata: metadata) {
                return updated
            }
        }

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

    /// Creates a new memory with semantic deduplication (async version).
    ///
    /// Prefer this over the sync version when calling from async contexts.
    @discardableResult
    public func createMemoryAsync(
        content: String,
        category: String = "general",
        source: String? = nil,
        tags: [String]? = nil,
        metadata: String? = nil
    ) async throws -> Memory {
        // Semantic deduplication: if a similar memory exists, update it instead
        let dupResult = try await checkDuplicateAsync(content: content)
        if case .similarExists(let existingId, _) = dupResult {
            if let updated = try await updateMemoryAsync(id: existingId, content: content, category: category, source: source, metadata: metadata) {
                return updated
            }
        }

        // Generate embedding using async API
        let embeddingData: Data?
        if let embeddingService {
            if let vector = await embeddingService.embedAsync(content, isQuery: false) {
                embeddingData = EmbeddingService.encodeEmbedding(vector)
            } else {
                embeddingData = nil
            }
        } else {
            embeddingData = nil
        }

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

        try await db.writer().write { dbConn in
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

    /// Updates an existing memory (async version). Returns the updated memory, or nil if not found.
    ///
    /// Prefer this over the sync version when calling from async contexts.
    @discardableResult
    public func updateMemoryAsync(
        id: String,
        content: String? = nil,
        category: String? = nil,
        source: String? = nil,
        metadata: String? = nil
    ) async throws -> Memory? {
        // Pre-compute embedding outside the database write transaction
        let newEmbeddingData: Data?
        if let content, let embeddingService {
            if let vector = await embeddingService.embedAsync(content, isQuery: false) {
                newEmbeddingData = EmbeddingService.encodeEmbedding(vector)
            } else {
                newEmbeddingData = nil
            }
        } else {
            newEmbeddingData = nil
        }

        let result: Memory? = try await db.writer().write { dbConn -> Memory? in
            guard var memory = try Memory.fetchOne(dbConn, key: id) else {
                return nil
            }

            if let content {
                memory.content = content
                memory.contentHash = Self.generateContentHash(content)
                memory.embedding = newEmbeddingData
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

            // Collect tag IDs associated with this memory BEFORE deletion,
            // so we only check these specific tags for orphan status afterwards.
            // This avoids a broad scan that could remove tags being concurrently
            // created by another DatabasePool connection on the same file.
            let tagIds = try Int64.fetchAll(
                dbConn,
                sql: "SELECT tag_id FROM memory_tag WHERE memory_id = ?",
                arguments: [id]
            )

            try memory.delete(dbConn)

            // Clean up only the specific tags that were associated with the
            // deleted memory AND are now orphaned (no remaining associations).
            if !tagIds.isEmpty {
                let placeholders = tagIds.map { _ in "?" }.joined(separator: ", ")
                var arguments: [any DatabaseValueConvertible] = []
                for tagId in tagIds { arguments.append(tagId) }
                // Append the same tagIds again for the subquery
                for tagId in tagIds { arguments.append(tagId) }
                try dbConn.execute(
                    sql: """
                        DELETE FROM tag
                        WHERE id IN (\(placeholders))
                          AND id NOT IN (
                            SELECT DISTINCT tag_id FROM memory_tag
                            WHERE tag_id IN (\(placeholders))
                          )
                        """,
                    arguments: StatementArguments(arguments)
                )
            }

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
            let semanticResults = try batchedEmbeddingSearch(
                query: queryVec,
                category: category,
                tags: tags,
                topK: effectiveLimit * 3,
                threshold: 0.3
            )
            for result in semanticResults {
                semanticScores[result.id] = result.similarity
            }
        }

        return try rankAndMerge(
            keywordResults: keywordResults,
            semanticScores: semanticScores,
            effectiveLimit: effectiveLimit
        )
    }

    /// Hybrid search (async version).
    ///
    /// Prefer this over the sync version when calling from async contexts.
    public func searchMemoriesAsync(
        query: String,
        category: String? = nil,
        tags: [String]? = nil,
        limit: Int = 20
    ) async throws -> [Memory] {
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
            limit: effectiveLimit * 3
        )

        // Phase 2: Semantic search (if embedding available)
        var semanticScores: [String: Float] = [:]
        if let embeddingService {
            if let queryVec = await embeddingService.embedAsync(query) {
                let semanticResults = try batchedEmbeddingSearch(
                    query: queryVec,
                    category: category,
                    tags: tags,
                    topK: effectiveLimit * 3,
                    threshold: 0.3
                )
                for result in semanticResults {
                    semanticScores[result.id] = result.similarity
                }
            }
        }

        return try rankAndMerge(
            keywordResults: keywordResults,
            semanticScores: semanticScores,
            effectiveLimit: effectiveLimit
        )
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
                let ftsQuery = ftsTerms.map { term in
                    // Strip FTS5 special characters: double quotes, asterisks, carets, colons, parentheses, plus, minus, NOT/AND/OR/NEAR handled by quoting
                    let sanitized = term
                        .replacingOccurrences(of: "\\", with: "")
                        .replacingOccurrences(of: "\"", with: "\"\"")
                        .replacingOccurrences(of: ":", with: "")
                        .replacingOccurrences(of: "*", with: "")
                        .replacingOccurrences(of: "^", with: "")
                    return "\"\(sanitized)\""
                }.joined(separator: " OR ")
                unionParts.append("""
                    SELECT memory.*, memory_fts.rank AS search_rank
                    FROM memory
                    INNER JOIN memory_fts ON memory_fts.id = memory.id
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

    /// Batched vector search: loads embeddings in batches to avoid unbounded memory usage,
    /// accumulating the top-K results across all batches.
    private static let embeddingBatchSize = 10_000

    private func batchedEmbeddingSearch(
        query: [Float],
        category: String? = nil,
        tags: [String]? = nil,
        topK: Int = 10,
        threshold: Float = 0.3
    ) throws -> [(id: String, similarity: Float)] {
        var accumulated: [(id: String, similarity: Float)] = []
        var offset = 0
        let batchSize = Self.embeddingBatchSize

        while true {
            let batch = try loadEmbeddings(category: category, tags: tags, limit: batchSize, offset: offset)
            if batch.isEmpty { break }

            let batchResults = EmbeddingService.search(
                query: query,
                candidates: batch,
                topK: topK,
                threshold: threshold
            )
            accumulated.append(contentsOf: batchResults)
            // Keep only topK across accumulated results
            accumulated.sort { $0.similarity > $1.similarity }
            if accumulated.count > topK {
                accumulated = Array(accumulated.prefix(topK))
            }

            if batch.count < batchSize { break }
            offset += batchSize
        }

        return accumulated
    }

    /// Load embeddings from database for vector search with pagination.
    private func loadEmbeddings(
        category: String? = nil,
        tags: [String]? = nil,
        limit: Int = 10_000,
        offset: Int = 0
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

            sql += " ORDER BY id LIMIT ? OFFSET ?"
            arguments.append(limit)
            arguments.append(offset)

            let rows = try Row.fetchAll(dbConn, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row -> (id: String, embedding: [Float])? in
                guard let id: String = row["id"],
                      let data: Data = row["embedding"]
                else { return nil }
                return (id: id, embedding: EmbeddingService.decodeEmbedding(data))
            }
        }
    }

    /// Merge keyword and semantic results, score, rank, and return top results.
    private func rankAndMerge(
        keywordResults: [KeywordResult],
        semanticScores: [String: Float],
        effectiveLimit: Int
    ) throws -> [Memory] {
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
            let recencyScore = exp(-0.693 * ageInDays / 30.0)

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
                finalScore = 0.35 * kScore + 0.35 * sScore + 0.15 * recencyScore + 0.15 * freqScore
            } else if hasKeyword {
                finalScore = 0.55 * kScore + 0.25 * recencyScore + 0.20 * freqScore
            } else {
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

            // Collect the tag IDs we're about to remove BEFORE deletion,
            // so we only check these specific tags for orphan status afterwards.
            var fetchArgs: [any DatabaseValueConvertible] = []
            for tag in tags { fetchArgs.append(tag) }
            let affectedTagIds = try Int64.fetchAll(
                dbConn,
                sql: "SELECT id FROM tag WHERE name IN (\(placeholders))",
                arguments: StatementArguments(fetchArgs)
            )

            var deleteArgs: [any DatabaseValueConvertible] = [memoryId]
            for tag in tags { deleteArgs.append(tag) }

            try dbConn.execute(
                sql: """
                    DELETE FROM memory_tag
                    WHERE memory_id = ?
                      AND tag_id IN (
                        SELECT id FROM tag WHERE name IN (\(placeholders))
                      )
                    """,
                arguments: StatementArguments(deleteArgs)
            )

            // Clean up only the specific tags that were just unlinked AND
            // are now orphaned (no remaining associations). This avoids a
            // broad scan that could remove tags being concurrently created
            // by another DatabasePool connection on the same file.
            if !affectedTagIds.isEmpty {
                let tagPlaceholders = affectedTagIds.map { _ in "?" }.joined(separator: ", ")
                var orphanArgs: [any DatabaseValueConvertible] = []
                for tagId in affectedTagIds { orphanArgs.append(tagId) }
                for tagId in affectedTagIds { orphanArgs.append(tagId) }
                try dbConn.execute(
                    sql: """
                        DELETE FROM tag
                        WHERE id IN (\(tagPlaceholders))
                          AND id NOT IN (
                            SELECT DISTINCT tag_id FROM memory_tag
                            WHERE tag_id IN (\(tagPlaceholders))
                          )
                        """,
                    arguments: StatementArguments(orphanArgs)
                )
            }
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

    /// Returns the number of memories in a specific category using a COUNT query.
    public func countMemories(category: String) throws -> Int {
        try db.reader().read { dbConn in
            try Memory.filter(Column("category") == category).fetchCount(dbConn)
        }
    }

    // MARK: - Embedding Management

    /// Generate and store embeddings for all memories that don't have one yet.
    ///
    /// Embeddings are written in batches (default 50) within a single transaction per batch
    /// to reduce inconsistency if the process is interrupted mid-backfill. If a memory is
    /// deleted between the read and write phases, the UPDATE safely affects 0 rows.
    /// Note: if the process crashes mid-backfill, some memories may have embeddings while
    /// others do not, which can bias semantic search results. Re-run backfill to complete.
    public func backfillEmbeddings(batchSize: Int = 50) throws -> Int {
        guard let embeddingService else { return 0 }

        let memories = try db.reader().read { dbConn in
            try Memory.filter(Column("embedding") == nil).fetchAll(dbConn)
        }

        var count = 0
        var batch: [(Data, String)] = []

        for memory in memories {
            if let vector = embeddingService.embed(memory.content, isQuery: false) {
                let data = EmbeddingService.encodeEmbedding(vector)
                batch.append((data, memory.id))
            }

            if batch.count >= batchSize {
                try db.writer().write { dbConn in
                    for (data, id) in batch {
                        try dbConn.execute(
                            sql: "UPDATE memory SET embedding = ? WHERE id = ?",
                            arguments: [data, id]
                        )
                    }
                }
                count += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }

        // Write remaining batch
        if !batch.isEmpty {
            try db.writer().write { dbConn in
                for (data, id) in batch {
                    try dbConn.execute(
                        sql: "UPDATE memory SET embedding = ? WHERE id = ?",
                        arguments: [data, id]
                    )
                }
            }
            count += batch.count
        }

        return count
    }

    /// Generate and store embeddings for all memories that don't have one yet (async version).
    ///
    /// Prefer this over the sync version when calling from async contexts.
    /// Embeddings are written in batches (default 50) within a single transaction per batch
    /// to reduce inconsistency if the process is interrupted mid-backfill. If a memory is
    /// deleted between the read and write phases, the UPDATE safely affects 0 rows.
    /// Note: if the process crashes mid-backfill, some memories may have embeddings while
    /// others do not, which can bias semantic search results. Re-run backfill to complete.
    public func backfillEmbeddingsAsync(batchSize: Int = 50) async throws -> Int {
        guard let embeddingService else { return 0 }

        let memories = try await db.reader().read { dbConn in
            try Memory.filter(Column("embedding") == nil).fetchAll(dbConn)
        }

        var count = 0
        var batch: [(Data, String)] = []

        for memory in memories {
            if let vector = await embeddingService.embedAsync(memory.content, isQuery: false) {
                let data = EmbeddingService.encodeEmbedding(vector)
                batch.append((data, memory.id))
            }

            if batch.count >= batchSize {
                let currentBatch = batch
                try await db.writer().write { dbConn in
                    for (data, id) in currentBatch {
                        try dbConn.execute(
                            sql: "UPDATE memory SET embedding = ? WHERE id = ?",
                            arguments: [data, id]
                        )
                    }
                }
                count += batch.count
                batch.removeAll(keepingCapacity: true)
            }
        }

        // Write remaining batch
        if !batch.isEmpty {
            let currentBatch = batch
            try await db.writer().write { dbConn in
                for (data, id) in currentBatch {
                    try dbConn.execute(
                        sql: "UPDATE memory SET embedding = ? WHERE id = ?",
                        arguments: [data, id]
                    )
                }
            }
            count += batch.count
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
