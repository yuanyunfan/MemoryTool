import Foundation

/// A thin proxy that bridges stdio ↔ Unix Domain Socket.
///
/// When a MemoryMCP instance detects an existing daemon, it runs as a proxy:
/// - Reads JSON-RPC from stdin → forwards to daemon over UDS
/// - Reads responses from daemon UDS → writes to stdout
///
/// Memory footprint: ~5-10 MB (no model, no database).
enum ProxyBridge {

    /// Run the proxy loop. This function blocks until stdin closes
    /// AND all pending daemon responses have been forwarded.
    ///
    /// - Parameter daemonFd: Connected file descriptor to the daemon's UDS.
    static func run(daemonFd: Int32) async {
        logToStderr("Running as proxy, forwarding to daemon...")

        let stdinFd = FileHandle.standardInput.fileDescriptor
        let stdoutFd = FileHandle.standardOutput.fileDescriptor

        // Set both fds to non-blocking
        setNonBlocking(stdinFd)
        setNonBlocking(daemonFd)

        let bufferSize = 65536
        var stdinClosed = false

        while !Task.isCancelled {
            // Poll stdin → daemon
            if !stdinClosed {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }

                let bytesRead = read(stdinFd, buffer, bufferSize)
                if bytesRead > 0 {
                    if !writeAll(daemonFd, buffer, bytesRead) {
                        logToStderr("Proxy: daemon write failed")
                        break
                    }
                } else if bytesRead == 0 {
                    // stdin EOF — Claude session ended
                    logToStderr("Proxy: stdin closed.")
                    stdinClosed = true
                    // Send EOF to daemon by shutting down write side
                    shutdown(daemonFd, SHUT_WR)
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    logToStderr("Proxy: stdin read error: \(String(cString: strerror(errno)))")
                    stdinClosed = true
                    shutdown(daemonFd, SHUT_WR)
                }
            }

            // Poll daemon → stdout
            do {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }

                let bytesRead = read(daemonFd, buffer, bufferSize)
                if bytesRead > 0 {
                    if !writeAll(stdoutFd, buffer, bytesRead) {
                        logToStderr("Proxy: stdout write failed")
                        break
                    }
                } else if bytesRead == 0 {
                    // Daemon disconnected
                    logToStderr("Proxy: daemon disconnected.")
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    logToStderr("Proxy: daemon read error: \(String(cString: strerror(errno)))")
                    break
                }
            }

            // If stdin is closed and nothing to read from daemon, we're done
            if stdinClosed {
                // Give daemon a moment to flush its response
                try? await Task.sleep(for: .milliseconds(10))

                // Check if daemon has more data
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
                defer { buffer.deallocate() }
                let peek = read(daemonFd, buffer, 1)
                if peek == 0 {
                    break // Daemon finished sending
                } else if peek > 0 {
                    // There was data — write it and continue
                    _ = write(stdoutFd, buffer, 1)
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    // No data yet, keep waiting briefly
                    continue
                } else {
                    break
                }
            }

            // Yield to avoid busy-spinning
            try? await Task.sleep(for: .milliseconds(1))
        }

        close(daemonFd)
        logToStderr("Proxy shutting down.")
    }

    // MARK: - Helpers

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Write all bytes to a file descriptor. Returns false on error.
    private static func writeAll(_ fd: Int32, _ buffer: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        var totalWritten = 0
        while totalWritten < count {
            let written = write(fd, buffer + totalWritten, count - totalWritten)
            if written <= 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Brief spin for writable — in practice UDS buffers rarely fill
                    usleep(100)
                    continue
                }
                return false
            }
            totalWritten += written
        }
        return true
    }
}
