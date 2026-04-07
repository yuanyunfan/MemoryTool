import Accelerate
import Embeddings
import Foundation

/// Provides multilingual text embedding using `intfloat/multilingual-e5-small`.
///
/// Single model, single vector space for 100+ languages — Chinese and English
/// queries find each other naturally. Uses XLM-RoBERTa architecture via
/// `swift-embeddings`.
///
/// Important: e5 models require prefixes:
/// - "query: " for search queries
/// - "passage: " for stored content
public final class EmbeddingService: @unchecked Sendable {
    /// Embedding dimension (384 for multilingual-e5-small).
    public static let dimension: Int = 384

    /// Whether the embedding model is loaded and ready.
    public private(set) var isAvailable: Bool = false

    private var modelBundle: XLMRoberta.ModelBundle?

    /// HuggingFace model identifier.
    private let modelId = "intfloat/multilingual-e5-small"

    public init() {}

    // MARK: - Setup

    /// Load the multilingual embedding model.
    ///
    /// First call downloads ~460MB from HuggingFace (cached for subsequent runs).
    /// Subsequent calls load from cache in ~2-5 seconds.
    public func loadModel() async {
        do {
            modelBundle = try await XLMRoberta.loadModelBundle(from: modelId)
            isAvailable = true
            logToStderr("EmbeddingService: Model loaded successfully (\(modelId), \(Self.dimension)-dim)")
        } catch {
            logToStderr("EmbeddingService: Failed to load model: \(error)")
            isAvailable = false
        }
    }

    // MARK: - Embedding Generation

    /// Generate an embedding for a text string.
    ///
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - isQuery: If true, prefixes with "query: " (for search).
    ///              If false, prefixes with "passage: " (for storage).
    /// - Returns: L2-normalized 384-dim Float array, or nil if model unavailable.
    public func embed(_ text: String, isQuery: Bool = true) -> [Float]? {
        guard let modelBundle, isAvailable else { return nil }

        let prefix = isQuery ? "query: " : "passage: "
        let prefixedText = prefix + text

        // swift-embeddings encode returns MLTensor; shapedArray is async,
        // so we bridge to sync via a semaphore for use in non-async contexts.
        nonisolated(unsafe) var result: [Float]?
        let semaphore = DispatchSemaphore(value: 0)

        Task { @Sendable in
            do {
                let encoded = try modelBundle.encode(prefixedText)
                let shaped = await encoded.cast(to: Float.self).shapedArray(of: Float.self)
                let vector = Array(shaped.scalars)
                if vector.count == Self.dimension {
                    result = self.l2Normalize(vector)
                } else {
                    logToStderr("EmbeddingService: Unexpected dimension \(vector.count), expected \(Self.dimension)")
                }
            } catch {
                logToStderr("EmbeddingService: Embedding failed: \(error)")
            }
            semaphore.signal()
        }

        semaphore.wait()
        return result
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

    /// Compute cosine similarity between two L2-normalized vectors (= dot product).
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }

    /// Search for the most similar vectors.
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
