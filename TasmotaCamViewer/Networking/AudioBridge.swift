import Foundation
import UIKit

/// ViewModel for the audio intercom feature.
///
/// Manages the UDP audio bridge lifecycle: control commands, mic capture, and speaker playback.
/// Push-to-talk: hold to talk (sends `cmd:1`), release to listen (sends `cmd:2`).
@Observable
final class AudioBridge {

    // MARK: - Observable State

    /// Current audio bridge state.
    var state: AudioBridgeState = .idle

    /// Whether the microphone is muted (capture still runs but packets are not sent).
    var isMicMuted: Bool = false

    /// Whether the speaker is muted (packets received but not played).
    var isSpeakerMuted: Bool = false

    /// Automatically start listening when connected to the ESP32.
    var autoListen: Bool = true

    /// Speaker volume / gain (1.0 – 10.0). Controls playback amplification.
    var speakerVolume: Float = 4.0 {
        didSet { audioEngine.playbackGain = speakerVolume }
    }

    // MARK: - Private

    private let client = UDPAudioClient()
    private let audioEngine = AudioEngine()
    private var eventTask: Task<Void, Never>?
    private var currentHost: String = ""

    // MARK: - Lifecycle

    deinit {
        eventTask?.cancel()
        client.cancel()
        audioEngine.stopAll()
    }

    // MARK: - Public Methods

    /// Connect to the ESP32 host (sets up UDP sockets, does NOT start audio yet).
    func connect(to host: String) {
        disconnect()

        guard !host.isEmpty else {
            state = .error("No host specified")
            return
        }

        currentHost = host
        state = .connecting

        let eventStream = client.connect(to: host)

        eventTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                guard let self, !Task.isCancelled else { break }

                switch event {
                case .connected:
                    if self.state == .connecting {
                        self.state = .idle
                        print("[AudioBridge] Connected to \(host)")
                        if self.autoListen {
                            self.startListening()
                        }
                    }

                case .audioData(let data):
                    self.handleReceivedAudio(data)

                case .error(let error):
                    self.state = .error(error.localizedDescription)
                    print("[AudioBridge] Error: \(error.localizedDescription)")

                case .completed:
                    self.state = .idle
                }
            }
        }
    }

    /// Disconnect from the ESP32 and stop all audio.
    func disconnect() {
        // Tell ESP32 to stop — use synchronous POSIX send so it works during app termination
        client.sendStopSync()

        eventTask?.cancel()
        eventTask = nil
        client.cancel()
        audioEngine.stopAll()

        currentHost = ""
        state = .idle
    }

    /// Start listening to ESP32 microphone audio (sends `cmd:2` so ESP32 captures and sends).
    func startListening() {
        guard state != .listening else { return }

        // Tell ESP32 to capture mic and send audio to us
        client.sendControl(Constants.audioCmdWrite)

        do {
            try audioEngine.startPlayback()
            audioEngine.playbackGain = speakerVolume
            state = .listening
            print("[AudioBridge] Listening — ESP32 mic → iPad speaker")
        } catch {
            state = .error("Playback error: \(error.localizedDescription)")
            print("[AudioBridge] Playback start error: \(error)")
        }
    }

    /// Start talking to ESP32 speaker (sends `cmd:1` so ESP32 receives and plays audio).
    func startTalking() {
        guard state != .talking else { return }

        // Tell ESP32 to receive audio and play on speaker
        client.sendControl(Constants.audioCmdRead)

        // Stop playback while talking (half-duplex)
        audioEngine.stopPlayback()

        do {
            try audioEngine.startCapture()
            audioEngine.onCapturedBuffer = { [weak self] data in
                guard let self, !self.isMicMuted else { return }
                self.client.sendAudio(data)
            }
            state = .talking
            print("[AudioBridge] Talking — iPad mic → ESP32 speaker")
        } catch {
            state = .error("Capture error: \(error.localizedDescription)")
            print("[AudioBridge] Capture start error: \(error)")
        }
    }

    /// Stop audio (sends `cmd:0`). Keeps the UDP connection alive.
    func stopAudio() {
        client.sendControl(Constants.audioCmdStop)
        audioEngine.stopAll()
        state = .idle
        print("[AudioBridge] Audio stopped")
    }

    /// Request microphone permission.
    func requestMicPermission() async -> Bool {
        await AudioEngine.requestMicPermission()
    }

    // MARK: - Private

    private var rxPacketCount: UInt64 = 0

    private func handleReceivedAudio(_ data: Data) {
        rxPacketCount += 1
        if rxPacketCount == 1 {
            print("[AudioBridge] First audio packet received: \(data.count) bytes, state=\(state), muted=\(isSpeakerMuted)")
        } else if rxPacketCount % 500 == 0 {
            print("[AudioBridge] Received \(rxPacketCount) audio packets")
        }
        guard state == .listening, !isSpeakerMuted else { return }
        audioEngine.enqueuePlayback(data)
    }
}
