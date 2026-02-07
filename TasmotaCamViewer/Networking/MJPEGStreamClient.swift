import Foundation
import Network
import UIKit

/// Network client that connects to an MJPEG HTTP stream using raw TCP.
///
/// Tasmota's ESP32-CAM writes its HTTP response (including the multipart
/// Content-Type header) directly to the TCP socket. URLSession's HTTP parser
/// misinterprets the per-frame headers as the HTTP response, so we bypass it
/// entirely and use NWConnection for raw TCP access.
///
/// The wire sequence from Tasmota is:
/// 1. We send: `GET /stream HTTP/1.1\r\nHost: <ip>\r\n\r\n`
/// 2. Tasmota replies: `HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace;boundary=<b>\r\n\r\n`
/// 3. Then for each frame:
///    `--<b>\r\nContent-Type: image/jpeg\r\nContent-Length: <len>\r\n\r\n<JPEG bytes>\r\n`
final class MJPEGStreamClient: @unchecked Sendable {

    // MARK: - Types

    enum Event: Sendable {
        case frame(UIImage)
        case error(StreamError)
        case completed
    }

    // MARK: - Properties

    private var connection: NWConnection?
    private var parser: MJPEGStreamParser?
    private var continuation: AsyncStream<Event>.Continuation?
    private var isActive = false
    private let queue = DispatchQueue(label: "MJPEGStreamClient.queue")

    // MARK: - Public

    /// Start streaming from the given URL.
    /// Returns an AsyncStream that yields frame images and error events.
    func stream(from url: URL) -> AsyncStream<Event> {
        cancel()

        return AsyncStream { continuation in
            self.continuation = continuation
            self.isActive = true
            self.httpHeadersParsed = false
            self.httpBuffer.removeAll()
            self.parser = MJPEGStreamParser(boundary: Constants.defaultTasmotaBoundary)

            guard let host = url.host, !host.isEmpty else {
                continuation.yield(.error(.invalidURL))
                continuation.finish()
                return
            }

            let port = UInt16(url.port ?? 81)
            let path = url.path.isEmpty ? "/stream" : url.path

            // Create raw TCP connection
            let nwHost = NWEndpoint.Host(host)
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let params = NWParameters.tcp
            // Allow local network connections
            params.requiredInterfaceType = .wifi

            let conn = NWConnection(host: nwHost, port: nwPort, using: params)
            self.connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    print("[MJPEGStreamClient] TCP connected to \(host):\(port)")
                    self.sendHTTPRequest(host: host, port: port, path: path)
                    self.startReceiving()
                case .failed(let error):
                    print("[MJPEGStreamClient] TCP connection failed: \(error)")
                    self.continuation?.yield(.error(.connectionFailed(underlying: error)))
                    self.continuation?.finish()
                case .cancelled:
                    print("[MJPEGStreamClient] TCP connection cancelled")
                    self.continuation?.yield(.completed)
                    self.continuation?.finish()
                case .waiting(let error):
                    print("[MJPEGStreamClient] TCP waiting: \(error)")
                default:
                    break
                }
            }

            conn.start(queue: self.queue)

            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    /// Cancel the current stream and clean up resources.
    func cancel() {
        isActive = false
        connection?.cancel()
        connection = nil
        parser = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    /// Send an HTTP GET request over the raw TCP connection.
    private func sendHTTPRequest(host: String, port: UInt16, path: String) {
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nAccept-Encoding: identity\r\nConnection: keep-alive\r\n\r\n"
        let data = Data(request.utf8)

        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                print("[MJPEGStreamClient] Failed to send HTTP request: \(error)")
                self?.continuation?.yield(.error(.connectionFailed(underlying: error)))
                self?.continuation?.finish()
            } else {
                print("[MJPEGStreamClient] HTTP GET sent for \(path)")
            }
        })
    }

    /// Continuously receive data from the TCP connection.
    private func startReceiving() {
        guard isActive, let connection else { return }

        // Receive up to 64KB at a time
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.isActive else { return }

            if let data, !data.isEmpty {
                self.processData(data)
            }

            if isComplete {
                print("[MJPEGStreamClient] TCP stream complete")
                self.continuation?.yield(.error(.streamTerminated))
                self.continuation?.finish()
                return
            }

            if let error {
                print("[MJPEGStreamClient] TCP receive error: \(error)")
                self.continuation?.yield(.error(.connectionFailed(underlying: error)))
                self.continuation?.finish()
                return
            }

            // Continue receiving
            self.startReceiving()
        }
    }

    /// Process received TCP data through the HTTP response parser and MJPEG parser.
    /// On first data, we strip the HTTP response status line + headers, then feed
    /// the remainder (multipart body) to the MJPEG parser.
    private var httpHeadersParsed = false
    private var httpBuffer = Data()

    private func processData(_ data: Data) {
        if !httpHeadersParsed {
            httpBuffer.append(data)

            // Look for end of HTTP headers: \r\n\r\n
            let headerEnd = Data("\r\n\r\n".utf8)
            guard let headerEndRange = httpBuffer.range(of: headerEnd) else {
                // Headers not complete yet — wait for more data
                return
            }

            // Parse HTTP status and headers
            let headersData = httpBuffer[httpBuffer.startIndex..<headerEndRange.lowerBound]
            if let headersString = String(data: headersData, encoding: .ascii) {
                print("[MJPEGStreamClient] HTTP Response Headers:\n\(headersString)")

                // Extract boundary from Content-Type if available
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

            // Feed any remaining data after the headers to the parser
            let bodyStart = headerEndRange.upperBound
            if bodyStart < httpBuffer.endIndex {
                let bodyData = httpBuffer[bodyStart...]
                feedParser(Data(bodyData))
            }
            httpBuffer.removeAll()
        } else {
            feedParser(data)
        }
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
