import SwiftUI

/// Floating overlay with push-to-talk button, listen toggle, mute controls, and volume slider.
struct AudioControlsOverlay: View {
    @Bindable var audio: AudioBridge

    @State private var isTalking = false

    var body: some View {
        VStack(spacing: 10) {
            // Main controls row
            HStack(spacing: 20) {
                // Listen toggle
                Button {
                    if audio.state == .listening {
                        audio.stopAudio()
                    } else {
                        audio.startListening()
                    }
                } label: {
                    Image(systemName: audio.state == .listening ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .imageScale(.large)
                        .foregroundStyle(audio.state == .listening ? .green : .secondary)
                        .frame(width: 44, height: 44)
                }

                // Mic mute
                Button {
                    audio.isMicMuted.toggle()
                } label: {
                    Image(systemName: audio.isMicMuted ? "mic.slash.fill" : "mic.fill")
                        .imageScale(.large)
                        .foregroundStyle(audio.isMicMuted ? .red : .secondary)
                        .frame(width: 44, height: 44)
                }

                // Push-to-talk button
                pttButton

                // Speaker mute
                Button {
                    audio.isSpeakerMuted.toggle()
                } label: {
                    Image(systemName: audio.isSpeakerMuted ? "speaker.slash.fill" : "speaker.fill")
                        .imageScale(.large)
                        .foregroundStyle(audio.isSpeakerMuted ? .red : .secondary)
                        .frame(width: 44, height: 44)
                }

                // State indicator
                Text(audio.state.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60)
            }

            // Volume slider row
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(value: $audio.speakerVolume, in: 1...10, step: 0.5)
                    .tint(.blue)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.0f%%", audio.speakerVolume * 10))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
            .padding(.horizontal, 4)

            // Auto-listen toggle
            Toggle("Auto-listen on connect", isOn: $audio.autoListen)
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.green)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Large push-to-talk button with press/release gesture.
    private var pttButton: some View {
        Circle()
            .fill(isTalking ? Color.red : Color.blue.opacity(0.8))
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: isTalking ? "mic.fill" : "mic")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .shadow(color: isTalking ? .red.opacity(0.4) : .clear, radius: 8)
            .scaleEffect(isTalking ? 1.1 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isTalking)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isTalking else { return }
                        isTalking = true
                        audio.startTalking()
                    }
                    .onEnded { _ in
                        isTalking = false
                        audio.startListening()
                    }
            )
    }
}
