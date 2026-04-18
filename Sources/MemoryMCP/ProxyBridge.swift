import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

        // Set all fds to non-blocking so reads/writes don't block after poll() wakeup
        setNonBlocking(stdinFd)
        setNonBlocking(stdoutFd)
        setNonBlocking(daemonFd)

        let bufferSize = 65536
        var stdinClosed = false

        while !Task.isCancelled {
            // Use poll() to wait for data on either fd, avoiding busy-spin.
            // Timeout of 100ms allows periodic checks of Task.isCancelled.
            var fds: [pollfd] = []
            if !stdinClosed {
                fds.append(pollfd(fd: stdinFd, events: Int16(POLLIN), revents: 0))
            }
            fds.append(pollfd(fd: daemonFd, events: Int16(POLLIN), revents: 0))

            let pollResult = poll(&fds, nfds_t(fds.count), 100 /* ms */)
            if pollResult < 0 {
                if errno == EINTR { continue }
                logToStderr("Proxy: poll error: \(String(cString: strerror(errno)))")
                break
            }

            // Resolve which pollfd corresponds to which fd
            var stdinRevents: Int16 = 0
            var daemonRevents: Int16 = 0
            if !stdinClosed {
                stdinRevents = fds[0].revents
                daemonRevents = fds[1].revents
            } else {
                daemonRevents = fds[0].revents
            }

            // Read stdin → daemon
            if !stdinClosed && (stdinRevents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
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

            // Read daemon → stdout
            if (daemonRevents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
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
                    // Use poll() to wait for fd to become writable instead of busy-spinning
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let pollResult = poll(&pfd, 1, 5000) // 5 second timeout
                    if pollResult < 0 {
                        return false // poll error
                    }
                    if pollResult == 0 {
                        // Timeout — fd still not writable
                        return false
                    }
                    continue
                }
                return false
            }
            totalWritten += written
        }
        return true
    }
}
