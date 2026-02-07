import Foundation

/// Represents the current state of the MJPEG stream connection.
enum StreamState: Equatable {
    case disconnected
    case connecting
    case streaming
    case error(String)
    case reconnecting(attempt: Int)

    var isActive: Bool {
        switch self {
        case .connecting, .streaming, .reconnecting:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting..."
        case .streaming:
            return "Streaming"
        case .error(let message):
            return message
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))..."
        }
    }
}
