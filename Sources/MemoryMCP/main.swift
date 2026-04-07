import Foundation
import MCP
import MemoryCore

// ─────────────────────────────────────────────────────────
// MCP servers must NOT use print() — stdout is reserved for
// the JSON-RPC protocol. All logging goes to stderr.
// ─────────────────────────────────────────────────────────

/// Write a log message to stderr.
func logToStderr(_ message: String) {
    FileHandle.standardError.write(Data("[MemoryMCP] \(message)\n".utf8))
}

// MARK: - Database Setup

/// Resolve the database path and initialise AppDatabase.
func createDatabase() throws -> AppDatabase {
    if let envPath = ProcessInfo.processInfo.environment["MEMORY_TOOL_DB_PATH"], !envPath.isEmpty {
        let dir = (envPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        logToStderr("Using database at \(envPath)")
        return try AppDatabase.create(path: envPath)
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let dir = "\(home)/.memorytool"
    try FileManager.default.createDirectory(
        atPath: dir,
        withIntermediateDirectories: true
    )
    let dbPath = "\(dir)/memory.db"
    logToStderr("Using database at \(dbPath)")
    return try AppDatabase.create(path: dbPath)
}

// MARK: - Main Entry Point

logToStderr("Starting...")

do {
    let database = try createDatabase()

    // Initialize embedding service for semantic search
    let embeddingService = EmbeddingService()
    await embeddingService.loadModel()
    if embeddingService.isAvailable {
        logToStderr("Embedding model loaded (multilingual-e5-small, \(EmbeddingService.dimension)-dim)")
    } else {
        logToStderr("Embedding model not available — semantic search disabled, keyword search only")
    }

    let service = MemoryService(database: database, embeddingService: embeddingService)

    // Backfill embeddings for existing memories
    let backfilled = try service.backfillEmbeddings()
    if backfilled > 0 {
        logToStderr("Backfilled embeddings for \(backfilled) memories")
    }

    let handler = ToolHandler(service: service)

    // Create the MCP Server
    let server = Server(
        name: "MemoryMCP",
        version: "0.1.0",
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )

    // Register tools/list handler
    await server.withMethodHandler(ListTools.self) { _ in
        .init(tools: ToolDefinitions.allTools)
    }

    // Register tools/call handler
    await server.withMethodHandler(CallTool.self) { params in
        try handler.handle(params)
    }

    // Start the server on stdio transport
    let transport = StdioTransport()
    logToStderr("Server ready, waiting for connections on stdio...")
    try await server.start(transport: transport)

    // Keep the process alive until the transport disconnects.
    // StdioTransport will close when stdin reaches EOF.
    // We use a simple sleep loop; in production consider swift-service-lifecycle.
    while true {
        try await Task.sleep(for: .seconds(60))
    }
} catch {
    logToStderr("Fatal error: \(error)")
    exit(1)
}
