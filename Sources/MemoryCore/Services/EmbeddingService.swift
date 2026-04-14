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
///
/// The model is loaded lazily on first use to avoid ~450MB GPU memory allocation
/// when no embedding operations are needed (e.g., idle MCP server).
public final class EmbeddingService: @unchecked Sendable {
    /// Embedding dimension (384 for multilingual-e5-small).
    public static let dimension: Int = 384

    /// Whether the embedding model is loaded and ready.
    public private(set) var isAvailable: Bool = false

    /// Whether the model has been loaded (or attempted to load).
    private var hasAttemptedLoad: Bool = false

    private var modelBundle: XLMRoberta.ModelBundle?

    /// HuggingFace model identifier.
    private let modelId = "intfloat/multilingual-e5-small"

    /// Mutex for thread-safe lazy loading state management.
    private let stateMutex = Mutex()

    public init() {}

    // MARK: - Setup

    /// Load the multilingual embedding model.
    ///
    /// First call downloads ~460MB from HuggingFace (cached for subsequent runs).
    /// Subsequent calls load from cache in ~2-5 seconds.
    public func loadModel() async {
        let shouldLoad = stateMutex.withLock {
            if hasAttemptedLoad { return false }
            hasAttemptedLoad = true
            return true
        }
        guard shouldLoad else { return }

        do {
            let bundle = try await XLMRoberta.loadModelBundle(from: modelId)
            stateMutex.withLock {
                modelBundle = bundle
                isAvailable = true
            }
            logToStderr("EmbeddingService: Model loaded successfully (\(modelId), \(Self.dimension)-dim)")
        } catch {
            stateMutex.withLock {
                isAvailable = false
            }
            logToStderr("EmbeddingService: Failed to load model: \(error)")
        }
    }

    /// Ensure the model is loaded. Call this before embedding operations.
    /// Thread-safe: only the first caller triggers the actual load.
    public func ensureLoaded() async {
        let needsLoad = stateMutex.withLock { !hasAttemptedLoad }
        if needsLoad {
            await loadModel()
        }
    }

    // MARK: - Embedding Generation

    /// Generate an embedding for a text string (async version).
    ///
    /// Lazily loads the model on first call.
    ///
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - isQuery: If true, prefixes with "query: " (for search).
    ///              If false, prefixes with "passage: " (for storage).
    /// - Returns: L2-normalized 384-dim Float array, or nil if model unavailable.
    public func embedAsync(_ text: String, isQuery: Bool = true) async -> [Float]? {
        await ensureLoaded()
        guard let modelBundle, isAvailable else { return nil }

        let prefix = isQuery ? "query: " : "passage: "
        let prefixedText = prefix + text

        do {
            let encoded = try modelBundle.encode(prefixedText)
            let shaped = await encoded.cast(to: Float.self).shapedArray(of: Float.self)
            let vector = Array(shaped.scalars)
            if vector.count == Self.dimension {
                return l2Normalize(vector)
            } else {
                logToStderr("EmbeddingService: Unexpected dimension \(vector.count), expected \(Self.dimension)")
                return nil
            }
        } catch {
            logToStderr("EmbeddingService: Embedding failed: \(error)")
            return nil
        }
    }

    /// Generate an embedding for a text string (sync version, for backward compatibility).
    ///
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - isQuery: If true, prefixes with "query: " (for search).
    ///              If false, prefixes with "passage: " (for storage).
    /// - Returns: L2-normalized 384-dim Float array, or nil if model unavailable.
    ///
    /// - Important: Prefer `embedAsync()` from async contexts to avoid deadlocks.
    ///   This sync version dispatches the semaphore wait to a non-cooperative GCD
    ///   thread to prevent deadlocking Swift concurrency's cooperative thread pool.
    public func embed(_ text: String, isQuery: Bool = true) -> [Float]? {
        guard let modelBundle, isAvailable else { return nil }

        let prefix = isQuery ? "query: " : "passage: "
        let prefixedText = prefix + text

        // Dispatch to a dedicated GCD thread so the semaphore.wait() never blocks
        // a Swift concurrency cooperative thread. The inner Task may need a
        // cooperative thread to run; if we blocked one with semaphore.wait(),
        // that could cause a deadlock under load.
        nonisolated(unsafe) var result: [Float]?
        let outerSemaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
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
            outerSemaphore.signal()
        }

        outerSemaphore.wait()
        return result
    }

    /// Encode embedding to Data for SQLite BLOB storage.
    public static func encodeEmbedding(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Decode embedding from SQLite BLOB Data.
    ///
    /// Returns an empty array if the data is malformed (length not a multiple of
    /// `MemoryLayout<Float>.size`, or does not match the expected dimension).
    public static func decodeEmbedding(_ data: Data) -> [Float] {
        let floatSize = MemoryLayout<Float>.size
        guard !data.isEmpty,
              data.count % floatSize == 0 else {
            logToStderr("EmbeddingService: decodeEmbedding failed — data length \(data.count) is not a multiple of \(floatSize)")
            return []
        }

        let floatCount = data.count / floatSize
        if floatCount != dimension {
            logToStderr("EmbeddingService: decodeEmbedding warning — decoded \(floatCount) floats, expected \(dimension)")
        }

        return data.withUnsafeBytes { raw in
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

// MARK: - Mutex (async-safe)

/// A simple unfair lock wrapper that is safe to use from both sync and async contexts.
private final class Mutex: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return body()
    }
}

/// Log to stderr (safe in MCP context where stdout is protocol channel).
private func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
