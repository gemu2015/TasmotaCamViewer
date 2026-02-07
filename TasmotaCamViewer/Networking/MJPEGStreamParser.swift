import Foundation
import UIKit

/// Parses an MJPEG multipart HTTP stream into individual JPEG frames.
/// Thread safety is provided by the URLSession serial delegate queue.
///
/// The Tasmota ESP32-CAM wire format:
/// ```
/// --<boundary>\r\n
/// Content-Type: image/jpeg\r\n
/// Content-Length: <length>\r\n
/// \r\n
/// <JPEG binary data>
/// \r\n
/// ```
final class MJPEGStreamParser {

    // MARK: - Types

    private enum ParserState {
        case seekingBoundary
        case readingHeaders
        case readingBody(expectedLength: Int?)
    }

    // MARK: - Properties

    private let boundaryMarker: Data  // "--<boundary>" as Data
    private let headerEnd: Data       // "\r\n\r\n" as Data
    private let lineEnd: Data         // "\r\n" as Data

    private var buffer: Data
    private var state: ParserState = .seekingBoundary

    // Statistics
    private(set) var totalFrames: Int = 0
    private(set) var droppedFrames: Int = 0

    // MARK: - Init

    /// Initialize with a boundary string.
    /// - Parameter boundary: The multipart boundary (without the leading "--").
    ///   Defaults to the known Tasmota boundary.
    init(boundary: String = Constants.defaultTasmotaBoundary) {
        self.boundaryMarker = Data("--\(boundary)".utf8)
        self.headerEnd = Data("\r\n\r\n".utf8)
        self.lineEnd = Data("\r\n".utf8)
        self.buffer = Data(capacity: Constants.parserBufferInitialCapacity)
        print("[Parser] Init with boundary: '--\(boundary)' (\(self.boundaryMarker.count) bytes)")
    }

    // MARK: - Public

    /// Feed raw bytes received from the network into the parser.
    /// Returns an array of decoded UIImage frames (typically 0 or 1 per call).
    func feed(_ data: Data) -> [UIImage] {
        buffer.append(data)
        var frames: [UIImage] = []

        // Process buffer in a loop — one feed() call may contain multiple frames
        while true {
            switch state {
            case .seekingBoundary:
                guard let boundaryRange = buffer.range(of: boundaryMarker) else {
                    // No boundary found yet. Trim buffer to avoid unbounded growth,
                    // but keep the tail in case boundary is split across chunks.
                    let keep = max(0, buffer.count - boundaryMarker.count)
                    if keep > 0 {
                        buffer.removeFirst(keep)
                    }
                    return frames
                }
                // Found boundary. Find the end of the boundary line (\r\n after boundary).
                let afterBoundary = boundaryRange.upperBound
                guard let lineEndRange = buffer.range(of: lineEnd, in: afterBoundary..<buffer.endIndex) else {
                    // Boundary found but line not complete yet — wait for more data
                    return frames
                }
                // Trim everything up to and including the boundary line
                buffer.removeSubrange(buffer.startIndex..<lineEndRange.upperBound)
                state = .readingHeaders

            case .readingHeaders:
                guard let headerEndRange = buffer.range(of: headerEnd) else {
                    // Headers not complete yet — wait for more data
                    return frames
                }
                // Extract headers
                let headersData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
                let contentLength = parseContentLength(from: headersData)

                // Remove headers and the \r\n\r\n separator
                buffer.removeSubrange(buffer.startIndex..<headerEndRange.upperBound)
                state = .readingBody(expectedLength: contentLength)

            case .readingBody(let expectedLength):
                if let length = expectedLength {
                    // We know the exact frame size from Content-Length
                    guard buffer.count >= length else {
                        // Not enough data yet — wait
                        return frames
                    }
                    let jpegData = buffer[buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: length)]
                    buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: length))

                    // Consume trailing \r\n if present
                    if buffer.starts(with: lineEnd) {
                        buffer.removeFirst(lineEnd.count)
                    }

                    if let image = decodeFrame(Data(jpegData)) {
                        frames.append(image)
                        totalFrames += 1
                    } else {
                        droppedFrames += 1
                    }
                    state = .seekingBoundary

                } else {
                    // No Content-Length — scan for the next boundary to find frame end
                    guard let nextBoundaryRange = buffer.range(of: boundaryMarker) else {
                        // Next boundary not found yet — wait for more data
                        // But cap buffer to prevent memory blowup (max 2MB for a single frame)
                        if buffer.count > 2_000_000 {
                            buffer.removeAll()
                            state = .seekingBoundary
                            droppedFrames += 1
                        }
                        return frames
                    }

                    // Frame data is everything before the boundary (minus trailing \r\n)
                    var frameEnd = nextBoundaryRange.lowerBound
                    // Check for \r\n before boundary
                    if frameEnd >= buffer.index(buffer.startIndex, offsetBy: lineEnd.count) {
                        let possibleLineEnd = buffer.index(frameEnd, offsetBy: -lineEnd.count)
                        if buffer[possibleLineEnd..<frameEnd] == lineEnd {
                            frameEnd = possibleLineEnd
                        }
                    }

                    let jpegData = buffer[buffer.startIndex..<frameEnd]
                    // Don't remove the boundary itself — seekingBoundary will find it
                    buffer.removeSubrange(buffer.startIndex..<nextBoundaryRange.lowerBound)

                    if let image = decodeFrame(Data(jpegData)) {
                        frames.append(image)
                        totalFrames += 1
                    } else {
                        droppedFrames += 1
                    }
                    state = .seekingBoundary
                }
            }
        }
    }

    /// Reset the parser state. Call when reconnecting.
    func reset() {
        buffer.removeAll(keepingCapacity: true)
        state = .seekingBoundary
    }

    // MARK: - Private

    /// Parse "Content-Length: <value>" from raw header bytes.
    private func parseContentLength(from headersData: Data) -> Int? {
        guard let headersString = String(data: headersData, encoding: .ascii) else {
            return nil
        }
        // Headers are separated by \r\n
        let lines = headersString.components(separatedBy: "\r\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("content-length:") {
                let valueString = trimmed.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)
                return Int(valueString)
            }
        }
        return nil
    }

    /// Validate JPEG SOI marker and decode to UIImage.
    private func decodeFrame(_ data: Data) -> UIImage? {
        guard data.count >= 2 else { return nil }

        // Validate JPEG Start-Of-Image marker: 0xFF 0xD8
        let firstTwo = [data[data.startIndex], data[data.index(after: data.startIndex)]]
        guard firstTwo[0] == 0xFF, firstTwo[1] == 0xD8 else {
            return nil
        }

        return UIImage(data: data)
    }
}
