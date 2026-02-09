import Foundation
import UIKit

/// Network client that connects to an MJPEG HTTP stream using POSIX TCP sockets.
///
/// Uses raw POSIX sockets instead of NWConnection to avoid iOS Network.framework
/// caching issues that prevent reconnection after disconnect.
final class MJPEGStreamClient: @unchecked Sendable {

    // MARK: - Types

    enum Event: Sendable {
        case frame(UIImage)
        case error(StreamError)
        case completed
    }

    // MARK: - Properties

    private var socketFD: Int32 = -1
    private var parser: MJPEGStreamParser?
    private var continuation: AsyncStream<Event>.Continuation?
    private var isActive = false
    private var receiveThread: Thread?

    // MARK: - Public

    /// Start streaming from the given URL.
    /// Returns an AsyncStream that yields frame images and error events.
    func stream(from url: URL) -> AsyncStream<Event> {
        cancel()

        return AsyncStream { continuation in
            self.continuation = continuation
            self.isActive = true
            self.parser = MJPEGStreamParser(boundary: Constants.defaultTasmotaBoundary)

            guard let host = url.host, !host.isEmpty else {
                continuation.yield(.error(.invalidURL))
                continuation.finish()
                return
            }

            let port = UInt16(url.port ?? 81)
            let path = url.path.isEmpty ? "/stream" : url.path

            // Start connection on a background thread
            let thread = Thread { [weak self] in
                self?.connectAndStream(host: host, port: port, path: path)
            }
            thread.name = "MJPEGStreamClient.stream"
            thread.qualityOfService = .userInteractive
            self.receiveThread = thread
            thread.start()

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// Cancel the current stream and clean up resources.
    func cancel() {
        isActive = false
        let fd = socketFD
        socketFD = -1
        if fd >= 0 {
            // Send graceful TCP FIN (not RST) so ESP32 detects disconnect cleanly
            // SHUT_WR sends FIN; recv() in the receive thread will return 0 or error
            shutdown(fd, SHUT_WR)
            // Give the receive thread a moment to exit its recv() call
            Thread.sleep(forTimeInterval: 0.05)
            close(fd)
        }
        receiveThread?.cancel()
        receiveThread = nil
        parser = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    /// Reset the ESP32 stream server via Tasmota HTTP API (port 80).
    private func resetStreamServer(host: String) {
        print("[MJPEGStreamClient] Resetting stream server via API...")
        let commands = ["wcstream%200", "wcstream%201"]
        for cmd in commands {
            guard isActive else { return }
            let urlStr = "http://\(host)/cm?cmnd=\(cmd)"
            guard let url = URL(string: urlStr) else { continue }

            let sem = DispatchSemaphore(value: 0)
            var task: URLSessionDataTask?
            task = URLSession.shared.dataTask(with: url) { _, _, _ in
                sem.signal()
            }
            task?.resume()
            _ = sem.wait(timeout: .now() + 3)
            if cmd.contains("0") {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("[MJPEGStreamClient] Stream server reset done")
    }

    /// Connect via POSIX TCP, send HTTP GET, then loop receiving data.
    private func connectAndStream(host: String, port: UInt16, path: String) {

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        host.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }

        // Try to connect, reset stream server if first attempt fails
        var fd: Int32 = -1
        var didReset = false

        for attempt in 1...10 {
            guard isActive else { return }

            fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else {
                print("[MJPEGStreamClient] Failed to create socket: \(String(cString: strerror(errno)))")
                continuation?.yield(.error(.connectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))))
                continuation?.finish()
                return
            }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            let connectResult = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if connectResult == 0 {
                break  // connected!
            }

            let err = errno
            close(fd)
            fd = -1

            // On first failure, reset the stream server
            if !didReset {
                didReset = true
                print("[MJPEGStreamClient] Connect refused, resetting stream server...")
                resetStreamServer(host: host)
                continue
            }

            if attempt == 10 || !isActive {
                print("[MJPEGStreamClient] Connect failed after \(attempt) attempts: \(String(cString: strerror(err)))")
                continuation?.yield(.error(.connectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(err)))))
                continuation?.finish()
                return
            }

            print("[MJPEGStreamClient] Connect attempt \(attempt) failed (\(String(cString: strerror(err)))), retrying...")
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard fd >= 0, isActive else { return }
        self.socketFD = fd

        print("[MJPEGStreamClient] TCP connected to \(host):\(port)")

        // Send HTTP GET request
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
        let sent = request.withCString { cstr in
            Darwin.send(fd, cstr, strlen(cstr), 0)
        }

        guard sent > 0, isActive else {
            print("[MJPEGStreamClient] Failed to send HTTP request")
            close(fd)
            socketFD = -1
            continuation?.yield(.error(.connectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))))
            continuation?.finish()
            return
        }

        print("[MJPEGStreamClient] HTTP GET sent for \(path)")

        // Receive loop
        var buffer = [UInt8](repeating: 0, count: 65536)
        var httpHeadersParsed = false
        var httpBuffer = Data()

        while isActive && socketFD >= 0 {
            let n = recv(fd, &buffer, buffer.count, 0)

            guard isActive else { break }

            if n > 0 {
                let data = Data(bytes: buffer, count: n)

                if !httpHeadersParsed {
                    httpBuffer.append(data)

                    let headerEnd = Data("\r\n\r\n".utf8)
                    guard let headerEndRange = httpBuffer.range(of: headerEnd) else {
                        continue
                    }

                    let headersData = httpBuffer[httpBuffer.startIndex..<headerEndRange.lowerBound]
                    if let headersString = String(data: headersData, encoding: .ascii) {
                        print("[MJPEGStreamClient] HTTP Response Headers:\n\(headersString)")

                        let lines = headersString.components(separatedBy: "\r\n")
                        for line in lines {
                            if line.lowercased().hasPrefix("content-type:") {
                                let contentType = String(line.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
                                if let boundary = extractBoundary(from: contentType) {
                                    print("[MJPEGStreamClient] Found boundary: '\(boundary)'")
                                    self.parser = MJPEGStreamParser(boundary: boundary)
                                }
                            }
                        }
                    }

                    httpHeadersParsed = true

                    let bodyStart = headerEndRange.upperBound
                    if bodyStart < httpBuffer.endIndex {
                        feedParser(Data(httpBuffer[bodyStart...]))
                    }
                    httpBuffer.removeAll()
                } else {
                    feedParser(data)
                }
            } else if n == 0 {
                // Connection closed by server
                print("[MJPEGStreamClient] TCP connection closed by server")
                break
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    continue
                }
                if !isActive || err == EBADF {
                    break
                }
                print("[MJPEGStreamClient] recv error: \(String(cString: strerror(err)))")
                continuation?.yield(.error(.connectionFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(err)))))
                break
            }
        }

        // Clean up
        if socketFD >= 0 {
            close(fd)
            socketFD = -1
        }

        if isActive {
            continuation?.yield(.error(.streamTerminated))
        }
        continuation?.finish()
    }

    private func feedParser(_ data: Data) {
        guard let parser else { return }
        let frames = parser.feed(data)
        for frame in frames {
            continuation?.yield(.frame(frame))
        }
    }

    /// Extract boundary string from a Content-Type value.
    private func extractBoundary(from contentType: String) -> String? {
        let components = contentType.components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                let boundary = String(trimmed.dropFirst("boundary=".count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return boundary.isEmpty ? nil : boundary
            }
        }
        return nil
    }
}
