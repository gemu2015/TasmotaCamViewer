import Foundation

/// Errors that can occur during MJPEG stream operation.
enum StreamError: Error, LocalizedError {
    case invalidURL
    case connectionFailed(underlying: Error)
    case httpError(statusCode: Int)
    case notMultipartResponse
    case streamTerminated
    case parseError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid camera URL"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .notMultipartResponse:
            return "Server did not return MJPEG stream"
        case .streamTerminated:
            return "Stream ended unexpectedly"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .timeout:
            return "Connection timed out"
        }
    }
}
