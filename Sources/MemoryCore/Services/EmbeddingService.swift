import Accelerate
import Foundation
import NaturalLanguage

/// Provides text embedding and vector similarity search using Apple's NLContextualEmbedding.
///
/// Uses system-built-in BERT models — zero external dependencies, zero model downloads.
/// Supports both English (Latin script) and Chinese (Han script).
public final class EmbeddingService: @unchecked Sendable {
    /// Embedding dimension (768 on macOS).
    public private(set) var dimension: Int = 768

    /// Whether the embedding model is ready to use.
    public private(set) var isAvailable: Bool = false

    private var latinEmbedding: NLContextualEmbedding?
    private var hanEmbedding: NLContextualEmbedding?

    public init() {}

    // MARK: - Setup

    /// Load embedding models. Call once at startup.
    public func loadModels() async {
        // Try to load Latin (English) model
        if let latin = NLContextualEmbedding(script: .latin) {
            do {
                try latin.load()
                self.latinEmbedding = latin
                self.dimension = latin.dimension
                self.isAvailable = true
            } catch {
                logToStderr("EmbeddingService: Failed to load Latin model: \(error)")
            }
        }

        // Try to load Han (Chinese) model
        if let han = NLContextualEmbedding(script: .simplifiedChinese) {
            do {
                try han.load()
                self.hanEmbedding = han
                self.isAvailable = true
            } catch {
                logToStderr("EmbeddingService: Failed to load Han model: \(error)")
            }
        }

        if !isAvailable {
            logToStderr("EmbeddingService: No embedding models available. Semantic search disabled.")
        }
    }

    // MARK: - Embedding Generation

    /// Generate a sentence embedding by mean-pooling token embeddings.
    ///
    /// Automatically detects language and uses the appropriate model.
    /// Returns nil if no suitable model is available or embedding fails.
    public func embed(_ text: String) -> [Float]? {
        guard isAvailable else { return nil }

        let model = selectModel(for: text)
        guard let model else { return nil }

        let language = detectLanguage(text)

        guard let result = try? model.embeddingResult(for: text, language: language) else {
            return nil
        }

        // Mean pooling: average all token vectors
        var sum = [Double](repeating: 0.0, count: model.dimension)
        var tokenCount = 0

        result.enumerateTokenVectors(
            in: text.startIndex..<text.endIndex
        ) { vector, _ in
            for i in 0..<min(vector.count, sum.count) {
                sum[i] += vector[i]
            }
            tokenCount += 1
            return true
        }

        guard tokenCount > 0 else { return nil }

        // Normalize to unit vector for cosine similarity
        let mean = sum.map { Float($0 / Double(tokenCount)) }
        return l2Normalize(mean)
    }

    /// Encode embedding to Data for SQLite BLOB storage.
    public static func encodeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Decode embedding from SQLite BLOB Data.
    public static func decodeEmbedding(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

    // MARK: - Vector Search

    /// Compute cosine similarity between two vectors.
    /// Both vectors should already be L2-normalized (returns dot product).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// Search for the most similar vectors.
    ///
    /// - Parameters:
    ///   - query: The query embedding vector (must be L2-normalized).
    ///   - candidates: Array of (id, embedding) pairs to search through.
    ///   - topK: Number of results to return.
    ///   - threshold: Minimum similarity score (0.0 to 1.0).
    /// - Returns: Array of (id, similarity) sorted by descending similarity.
    public static func search(
        query: [Float],
        candidates: [(id: String, embedding: [Float])],
        topK: Int = 10,
        threshold: Float = 0.3
    ) -> [(id: String, similarity: Float)] {
        candidates
            .map { (id: $0.id, similarity: cosineSimilarity(query, $0.embedding)) }
            .filter { $0.similarity >= threshold }
            .sorted { $0.similarity > $1.similarity }
            .prefix(topK)
            .map { $0 }
    }

    // MARK: - Private

    private func selectModel(for text: String) -> NLContextualEmbedding? {
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)

        switch lang {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return hanEmbedding ?? latinEmbedding
        default:
            return latinEmbedding ?? hanEmbedding
        }
    }

    private func detectLanguage(_ text: String) -> NLLanguage? {
        NLLanguageRecognizer.dominantLanguage(for: text)
    }

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return vector }

        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }
}

/// Log to stderr (safe in MCP context where stdout is protocol channel).
private func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
