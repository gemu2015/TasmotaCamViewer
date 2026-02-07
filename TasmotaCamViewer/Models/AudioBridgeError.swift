import Foundation

/// Errors that can occur during audio bridge operation.
enum AudioBridgeError: Error, LocalizedError {
    case invalidHost
    case udpConnectionFailed(underlying: Error)
    case microphonePermissionDenied
    case audioEngineError(String)
    case controlCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Invalid ESP32 IP address"
        case .udpConnectionFailed(let error):
            return "UDP connection failed: \(error.localizedDescription)"
        case .microphonePermissionDenied:
            return "Microphone access denied. Enable in Settings."
        case .audioEngineError(let message):
            return "Audio engine error: \(message)"
        case .controlCommandFailed(let message):
            return "Control command failed: \(message)"
        }
    }
}
