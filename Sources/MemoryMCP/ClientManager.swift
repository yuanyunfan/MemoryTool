import Foundation
import Logging
import MCP
import MemoryCore

#if canImport(System)
    import System
#else
    @preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin.POSIX
#endif

/// Manages multiple proxy client connections on the daemon side.
///
/// The daemon accepts connections from proxy instances via UDS,
/// and routes their JSON-RPC requests to the shared ToolHandler.
/// Each proxy client gets its own MCP Server + UDSTransport.
final class ClientManager: @unchecked Sendable {
    private let handler: ToolHandler
    private let clientCountMutex = ClientMutex()

    init(handler: ToolHandler) {
        self.handler = handler
    }

    /// Accept connections on the listening socket in a loop.
    /// Each accepted client is handled in its own Task.
    func acceptLoop(listenFd: Int32) async {
        logToStderr("Daemon: accepting proxy connections on UDS...")

        // Set listening socket to non-blocking
        let flags = fcntl(listenFd, F_GETFL)
        fcntl(listenFd, F_SETFL, flags | O_NONBLOCK)

        while !Task.isCancelled {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(listenFd, sockaddrPtr, &addrLen)
                }
            }

            if clientFd >= 0 {
                let count = clientCountMutex.increment()
                logToStderr("Daemon: proxy client connected (total: \(count))")

                Task { [handler] in
                    await Self.handleProxyClient(clientFd: clientFd, handler: handler)

                    let remaining = self.clientCountMutex.decrement()
                    logToStderr("Daemon: proxy client disconnected (remaining: \(remaining))")
                }
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try? await Task.sleep(for: .milliseconds(50))
                    continue
                }
                logToStderr("Daemon: accept error: \(String(cString: strerror(errno)))")
                try? await Task.sleep(for: .seconds(1))
            }
        }

        close(listenFd)
    }

    /// Handle a single proxy client connection.
    private static func handleProxyClient(clientFd: Int32, handler: ToolHandler) async {
        // Create a new MCP server instance for this client
        let clientServer = Server(
            name: "MemoryMCP",
            version: "0.1.0",
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        await clientServer.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolDefinitions.allTools)
        }

        await clientServer.withMethodHandler(CallTool.self) { params in
            try handler.handle(params)
        }

        // Use UDS transport with the client file descriptor
        let transport = UDSClientTransport(
            inputFd: FileDescriptor(rawValue: clientFd),
            outputFd: FileDescriptor(rawValue: clientFd)
        )

        do {
            try await clientServer.start(transport: transport)

            // Keep alive until the transport disconnects.
            // The server.start() handles message routing internally.
            // We wait until the transport's readLoop detects EOF.
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(60))
            }
        } catch {
            logToStderr("Daemon: client handler ended: \(error.localizedDescription)")
        }

        await clientServer.stop()
        close(clientFd)
    }
}

// MARK: - UDS Client Transport (actor, conforms to MCP Transport protocol)

/// MCP Transport that operates over a pair of Unix file descriptors.
///
/// Used by the daemon to communicate with each proxy client connection.
/// Follows the same pattern as StdioTransport from the MCP SDK.
actor UDSClientTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor

    public nonisolated let logger: Logger

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(inputFd: FileDescriptor, outputFd: FileDescriptor) {
        self.input = inputFd
        self.output = outputFd
        self.logger = Logger(
            label: "mcp.transport.uds",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }

        // Set non-blocking mode
        let flags = fcntl(input.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
        let result = fcntl(input.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }

        // Output might be the same fd for UDS
        if output.rawValue != input.rawValue {
            let oflags = fcntl(output.rawValue, F_GETFL)
            if oflags >= 0 {
                fcntl(output.rawValue, F_SETFL, oflags | O_NONBLOCK)
            }
        }

        isConnected = true

        Task {
            await readLoop()
        }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        var messageWithNewline = message
        messageWithNewline.append(UInt8(ascii: "\n"))

        var remaining = messageWithNewline
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                }
            } catch let error where isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                throw MCPError.transportError(error)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        return messageStream
    }

    // MARK: - Private

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    break // EOF
                }

                pendingData.append(Data(buffer[..<bytesRead]))

                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]

                    if !messageData.isEmpty {
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } catch let error where isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                if !Task.isCancelled {
                    logger.error("UDS read error: \(error)")
                }
                break
            }
        }

        messageContinuation.finish()
    }

    private nonisolated func isResourceTemporarilyUnavailable(_ error: Error) -> Bool {
        if let errno = error as? Errno {
            return errno == .resourceTemporarilyUnavailable || errno == .wouldBlock
        }
        return false
    }
}

// MARK: - Thread-safe counter

private final class ClientMutex: @unchecked Sendable {
    private var count = 0
    private var _lock = os_unfair_lock()

    func increment() -> Int {
        os_unfair_lock_lock(&_lock)
        count += 1
        let result = count
        os_unfair_lock_unlock(&_lock)
        return result
    }

    func decrement() -> Int {
        os_unfair_lock_lock(&_lock)
        count -= 1
        let result = count
        os_unfair_lock_unlock(&_lock)
        return result
    }
}
