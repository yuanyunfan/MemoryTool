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
    let (role, earlyListenFd) = DaemonManager.detectRole()

    switch role {
    case .proxy:
        // ──────────────────────────────────────────────────────
        // PROXY MODE: Forward stdio ↔ daemon via UDS (~5MB RSS)
        // ──────────────────────────────────────────────────────
        logToStderr("Daemon already running, entering proxy mode...")
        let daemonFd = try DaemonManager.connectToDaemon()
        await ProxyBridge.run(daemonFd: daemonFd)
        exit(0)

    case .daemon:
        // ──────────────────────────────────────────────────────
        // DAEMON MODE: Load model + DB, serve stdio + UDS clients
        // ──────────────────────────────────────────────────────
        logToStderr("No existing daemon, starting as daemon...")

        let database = try createDatabase()

        // Initialize embedding service — lazy load (model not loaded yet, ~0 MB).
        // Model will be loaded on first embed request (~450MB GPU memory).
        let embeddingService = EmbeddingService()

        // Check if MEMORY_TOOL_EAGER_LOAD is set to preload the model
        if ProcessInfo.processInfo.environment["MEMORY_TOOL_EAGER_LOAD"] != nil {
            await embeddingService.loadModel()
            if embeddingService.isAvailable {
                logToStderr("Embedding model preloaded (multilingual-e5-small, \(EmbeddingService.dimension)-dim)")
            } else {
                logToStderr("Embedding model preload failed — semantic search disabled")
            }
        } else {
            logToStderr("Embedding model will be loaded lazily on first use")
        }

        let service = MemoryService(database: database, embeddingService: embeddingService)

        // Backfill embeddings for existing memories (triggers model load if needed)
        let backfilled = try await service.backfillEmbeddingsAsync()
        if backfilled > 0 {
            logToStderr("Backfilled embeddings for \(backfilled) memories")
        }

        let handler = ToolHandler(service: service)

        // Create the MCP Server for this process's own stdio client
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
            try await handler.handle(params)
        }

        // Start the MCP server on stdio transport (for this process's own Claude session)
        let transport = StdioTransport()
        logToStderr("Server ready, waiting for connections on stdio...")
        try await server.start(transport: transport)

        // Start UDS listener for proxy clients
        let listenFd = try DaemonManager.becomeDaemon(listenFd: earlyListenFd)
        logToStderr("Daemon listening on \(DaemonManager.socketPath)")

        let clientManager = ClientManager(handler: handler)

        // Register cleanup handler with graceful shutdown
        var shutdownInProgress = false
        let signalSources = [SIGTERM, SIGINT].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                guard !shutdownInProgress else {
                    logToStderr("Received signal \(sig) again, shutdown already in progress. Ignoring.")
                    return
                }
                shutdownInProgress = true
                logToStderr("Received signal \(sig), initiating graceful shutdown...")

                Task {
                    // 1. Stop accepting new connections
                    // (gracefulShutdown cancels the accept loop internally)

                    // 2. Stop the stdio MCP server — finishes in-flight request processing
                    await server.stop()

                    // 3. Wait for in-flight proxy client requests to complete (with timeout)
                    await clientManager.gracefulShutdown(timeout: .seconds(5))

                    // 4. Clean up daemon files (listen socket is closed by acceptLoop)
                    DaemonManager.cleanupDaemon()

                    logToStderr("Graceful shutdown complete, exiting.")
                    exit(0)
                }
            }
            signal(sig, SIG_IGN) // Ignore default handler
            source.resume()
            return source
        }
        // Keep signal sources alive
        _ = signalSources

        // Run UDS accept loop in background
        clientManager.startAcceptLoop(listenFd: listenFd)

        // Monitor stdin closure through the StdioTransport's read loop.
        // When stdin closes, the transport's message stream ends and
        // server.waitUntilCompleted() returns. We avoid reading stdin
        // directly here to prevent competing with StdioTransport for data.
        Task {
            await server.waitUntilCompleted()
            logToStderr("Daemon's own stdin closed. Will continue serving proxy clients.")
        }

        // Keep the process alive. The daemon exits when:
        // 1. It receives SIGTERM/SIGINT (cleanup handler above)
        // 2. The accept loop ends (unlikely unless socket error)
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
} catch {
    logToStderr("Fatal error: \(error)")
    DaemonManager.cleanupDaemon()
    exit(1)
}
