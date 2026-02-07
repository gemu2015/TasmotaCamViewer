import SwiftUI

/// Toolbar content for the camera view — shows FPS, connection status, snapshot, audio, and settings buttons.
struct CameraToolbarView: ToolbarContent {
    let stream: MJPEGStream
    let audio: AudioBridge
    @Binding var audioEnabled: Bool
    @Binding var showSettings: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                // Connection indicator dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 16) {
                // Snapshot button
                Button {
                    stream.takeSnapshot()
                } label: {
                    Image(systemName: "camera.shutter.button")
                        .imageScale(.large)
                }
                .disabled(stream.currentFrame == nil)

                // Audio toggle button
                Button {
                    audioEnabled.toggle()
                } label: {
                    Image(systemName: audioEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .imageScale(.large)
                        .foregroundStyle(audioIconColor)
                }

                // Disconnect / Connect toggle
                Button {
                    if stream.state.isActive || stream.state == .streaming {
                        stream.disconnect()
                    } else {
                        stream.reconnect()
                    }
                } label: {
                    Image(systemName: stream.state.isActive ? "stop.fill" : "play.fill")
                        .imageScale(.large)
                }

                // Settings button
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
            }
        }
    }

    private var audioIconColor: Color {
        if !audioEnabled { return .secondary }
        switch audio.state {
        case .talking: return .red
        case .listening: return .green
        case .connecting: return .orange
        default: return .blue
        }
    }

    private var statusColor: Color {
        switch stream.state {
        case .streaming:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private var statusLabel: String {
        switch stream.state {
        case .streaming:
            return String(format: "%.1f FPS", stream.fps)
        case .connecting:
            return "Connecting..."
        case .reconnecting(let attempt):
            return "Retry \(attempt)..."
        case .error:
            return "Error"
        case .disconnected:
            return "Disconnected"
        }
    }
}
