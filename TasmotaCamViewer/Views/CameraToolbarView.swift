import SwiftUI

/// Toolbar content for the camera view — shows FPS, connection status, snapshot, audio, and settings buttons.
struct CameraToolbarView: ToolbarContent {
    let stream: MJPEGStream
    let audio: AudioBridge
    let recorder: StreamRecorder
    @Binding var audioEnabled: Bool
    @Binding var lightOn: Bool
    @Binding var showSettings: Bool
    var onToggleLight: () -> Void
    var onToggleRecording: () -> Void
    /// false on a narrow iPhone: six buttons leave no room for the text, it goes into a pill under the bar
    var showStatusText = true

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                // Connection indicator dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                if showStatusText {
                    Text(Self.statusLabel(for: stream))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

                // Record stream with sound
                Button {
                    onToggleRecording()
                } label: {
                    if recorder.isRecording, let since = recorder.startDate {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                                .imageScale(.large)
                                .foregroundStyle(.red)
                            TimelineView(.periodic(from: since, by: 1)) { ctx in
                                Text(Self.clock(ctx.date.timeIntervalSince(since)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        Image(systemName: "record.circle")
                            .imageScale(.large)
                            .foregroundStyle(.red)
                    }
                }
                .disabled(!recorder.isRecording && stream.state != .streaming)
                .help("Record the stream with sound")

                // Light toggle button
                Button {
                    onToggleLight()
                } label: {
                    Image(systemName: lightOn ? "lightbulb.fill" : "lightbulb")
                        .imageScale(.large)
                        .foregroundStyle(lightOn ? .yellow : .secondary)
                }

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

    private static func clock(_ t: TimeInterval) -> String {
        let n = max(0, Int(t))
        return String(format: "%02d:%02d", n / 60, n % 60)
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

    static func statusColor(for stream: MJPEGStream) -> Color {
        switch stream.state {
        case .streaming: return .green
        case .connecting, .reconnecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
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

    static func statusLabel(for stream: MJPEGStream) -> String {
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
