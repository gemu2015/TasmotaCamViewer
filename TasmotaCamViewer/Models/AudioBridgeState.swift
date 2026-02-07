import Foundation

/// Represents the current state of the audio bridge connection.
enum AudioBridgeState: Equatable {
    case idle
    case connecting
    case listening
    case talking
    case error(String)

    var isActive: Bool {
        switch self {
        case .listening, .talking:
            return true
        default:
            return false
        }
    }

    var statusText: String {
        switch self {
        case .idle:
            return "Audio off"
        case .connecting:
            return "Audio connecting..."
        case .listening:
            return "Listening"
        case .talking:
            return "Talking"
        case .error(let message):
            return message
        }
    }
}
