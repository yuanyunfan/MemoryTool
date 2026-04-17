import Foundation

/// Manages a singleton daemon process via Unix Domain Socket.
///
/// When multiple Claude Code sessions start MemoryMCP, only the first
/// becomes the "daemon" (loads model + DB). All subsequent instances
/// become thin proxies that forward JSON-RPC over the socket.
///
/// Architecture:
/// ```
/// Session 1 ──stdio──→ MemoryMCP (daemon, loads model ~450MB)
/// Session 2 ──stdio──→ MemoryMCP (proxy, ~5MB) ──UDS──→ daemon
/// Session N ──stdio──→ MemoryMCP (proxy, ~5MB) ──UDS──→ daemon
/// ```
enum DaemonManager {

    // MARK: - Configuration

    /// Maximum byte length for a Unix Domain Socket path (sun_path).
    /// macOS: 104, Linux: 108. We use 104 to be safe.
    private static let maxSocketPathLength = 104

    /// Path to the Unix Domain Socket.
    /// Falls back to `/tmp/memorytool-<uid>.sock` if the home-based path
    /// would exceed the platform's `sun_path` limit.
    static let socketPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = "\(home)/.memorytool/mcp.sock"
        // utf8CString includes the null terminator, so count must be <= maxSocketPathLength
        if preferred.utf8CString.count <= maxSocketPathLength {
            return preferred
        }
        let uid = getuid()
        return "/tmp/memorytool-\(uid).sock"
    }()

    /// Path to the daemon PID file.
    static let pidFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.memorytool/daemon.pid"
    }()

    /// Path to the lock file used to prevent race conditions during role detection.
    static let lockFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.memorytool/daemon.lock"
    }()

    // MARK: - Role Detection

    enum Role {
        /// This process is the daemon (first instance).
        case daemon
        /// Another daemon is running; this process should be a proxy.
        case proxy
    }

    /// Determine whether this process should be the daemon or a proxy.
    ///
    /// Logic:
    /// 1. Check if PID file exists and the process is alive
    /// 2. Try connecting to the socket
    /// 3. If both check out → proxy; otherwise → daemon
    ///
    /// This method acquires an exclusive file lock (flock) to prevent a race
    /// condition where two processes starting simultaneously could both detect
    /// no existing daemon and both attempt to become the daemon.
    ///
    /// When the role is `.daemon`, the listening socket is created and the PID
    /// file is written **while still holding the lock**, so that a second process
    /// running `detectRole()` concurrently will see both a live PID and a
    /// connectable socket. The caller receives the listening fd via the
    /// returned tuple and must pass it to `becomeDaemon(listenFd:)`.
    static func detectRole() -> (Role, Int32?) {
        // Ensure the directory exists
        let dir = (lockFilePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Open (or create) the lock file
        let lockFd = open(lockFilePath, O_CREAT | O_RDWR, 0o644)
        guard lockFd >= 0 else {
            // If we can't open the lock file, fall back to the old behavior
            return (detectRoleUnlocked(), nil)
        }

        // Acquire an exclusive lock — this blocks until the lock is available
        guard flock(lockFd, LOCK_EX) == 0 else {
            close(lockFd)
            return (detectRoleUnlocked(), nil)
        }

        let role = detectRoleUnlocked()

        var listenFd: Int32? = nil

        if role == .daemon {
            // Create the listening socket and write the PID file while still
            // holding the lock.  This ensures that any concurrent process
            // running detectRole() will find both a live PID **and** a
            // connectable socket, so it correctly becomes a proxy instead of
            // a second daemon.
            if let fd = try? createListeningSocket() {
                listenFd = fd
            }

            let pid = ProcessInfo.processInfo.processIdentifier
            try? "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        }

        // Release the lock
        flock(lockFd, LOCK_UN)
        close(lockFd)

        return (role, listenFd)
    }

    /// Internal role detection logic without locking.
    private static func detectRoleUnlocked() -> Role {
        // Check PID file
        if let pidString = try? String(contentsOfFile: pidFilePath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString),
           kill(pid, 0) == 0
        {
            // Process is alive, verify socket is connectable
            if canConnectToSocket() {
                return .proxy
            }
            // PID alive but socket dead → stale state, take over as daemon
        }

        // Clean up stale files
        cleanupStaleFiles()
        return .daemon
    }

    /// Try a quick TCP-style connect to the UDS.
    static func canConnectToSocket() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        return result == 0
    }

    // MARK: - Daemon Lifecycle

    /// Write PID file and return the listening socket.
    ///
    /// If `listenFd` is provided (created earlier by `detectRole()` while
    /// holding the lock), it is reused directly.  Otherwise a new listening
    /// socket is created as a fallback.
    static func becomeDaemon(listenFd existingFd: Int32? = nil) throws -> Int32 {
        // Write PID file (may already exist from detectRole, but re-write to be safe)
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)

        if let fd = existingFd {
            return fd
        }

        // Fallback: create listening socket now
        return try createListeningSocket()
    }

    /// Create a Unix Domain Socket, bind, and listen.  Returns the fd.
    private static func createListeningSocket() throws -> Int32 {
        // Remove stale socket file
        unlink(socketPath)

        // Create UDS listener
        let listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw DaemonError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(listenFd)
            throw DaemonError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(listenFd, sockaddrPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            close(listenFd)
            throw DaemonError.bindFailed(errno: errno)
        }

        guard listen(listenFd, 16) == 0 else {
            close(listenFd)
            throw DaemonError.listenFailed(errno: errno)
        }

        return listenFd
    }

    /// Connect to the daemon's UDS. Returns the connected file descriptor.
    static func connectToDaemon() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw DaemonError.socketPathTooLong
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for (i, byte) in pathBytes.enumerated() {
                bound[i] = byte
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }

        guard result == 0 else {
            close(fd)
            throw DaemonError.connectFailed(errno: errno)
        }

        return fd
    }

    // MARK: - Cleanup

    static func cleanupStaleFiles() {
        unlink(socketPath)
        unlink(pidFilePath)
    }

    /// Called when the daemon is shutting down.
    static func cleanupDaemon() {
        unlink(socketPath)
        unlink(pidFilePath)
    }
}

// MARK: - Errors

enum DaemonError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case socketPathTooLong
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): "Failed to create socket: \(String(cString: strerror(e)))"
        case .socketPathTooLong: "Socket path exceeds maximum length"
        case .bindFailed(let e): "Failed to bind socket: \(String(cString: strerror(e)))"
        case .listenFailed(let e): "Failed to listen on socket: \(String(cString: strerror(e)))"
        case .connectFailed(let e): "Failed to connect to daemon: \(String(cString: strerror(e)))"
        }
    }
}
