import SwiftUI

/// Root view that wires together the camera stream, audio bridge, toolbar, settings, and status banner.
struct ContentView: View {
    @State private var stream = MJPEGStream()
    @State private var audio = AudioBridge()
    @State private var showSettings = false

    @AppStorage("cameraURL") private var cameraURL: String = Constants.defaultStreamURL
    @AppStorage("autoConnect") private var autoConnect: Bool = true
    @AppStorage("audioEnabled") private var audioEnabled: Bool = false
    @AppStorage("speakerVolume") private var speakerVolume: Double = 1.0
    @AppStorage("autoListenOnConnect") private var autoListenOnConnect: Bool = true

    @Environment(\.scenePhase) private var scenePhase

    /// Extract the host IP from the camera URL.
    private var espHost: String? {
        URL(string: cameraURL)?.host
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Black background for cinematic camera feel
                Color.black.ignoresSafeArea()

                // Camera frame display
                CameraStreamView(stream: stream)

                // Connection status overlay
                ConnectionStatusBanner(state: stream.state) {
                    stream.reconnect()
                }

                // Audio controls overlay (bottom)
                if audioEnabled {
                    VStack {
                        Spacer()
                        AudioControlsOverlay(audio: audio)
                            .padding(.bottom, 16)
                    }
                }
            }
            .toolbar {
                CameraToolbarView(
                    stream: stream,
                    audio: audio,
                    audioEnabled: $audioEnabled,
                    showSettings: $showSettings
                )
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("TasmotaCam")
        }
        // Settings sheet
        .sheet(isPresented: $showSettings) {
            SettingsView(
                cameraURL: $cameraURL,
                autoConnect: $autoConnect,
                audioEnabled: $audioEnabled,
                speakerVolume: $speakerVolume,
                onConnect: {
                    audio.disconnect()
                    stream.disconnect()
                    stream.connect(to: cameraURL)
                    // audio will auto-connect when stream reaches .streaming
                }
            )
        }
        // Snapshot preview sheet
        .sheet(isPresented: $stream.showSnapshot) {
            if let snapshot = stream.lastSnapshot {
                SnapshotPreviewSheet(image: snapshot)
            }
        }
        // Auto-connect on launch
        .onAppear {
            audio.autoListen = autoListenOnConnect
            if autoConnect && !cameraURL.isEmpty {
                stream.connect(to: cameraURL)
                // audio connects once stream is up (see onChange of stream.state)
            }
        }
        // Start audio only after video stream is confirmed up
        .onChange(of: stream.state) { _, newState in
            if newState == .streaming && audioEnabled && audio.state == .idle {
                connectAudioIfEnabled()
            }
        }
        // Handle app lifecycle: disconnect on background, reconnect on foreground
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background:
                stream.disconnect()
                audio.disconnect()
            case .active:
                if oldPhase == .background && autoConnect && !cameraURL.isEmpty {
                    stream.connect(to: cameraURL)
                    // audio will auto-connect when stream reaches .streaming
                }
            default:
                break
            }
        }
        // Shut down audio bridge when the app is terminated
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            audio.disconnect()
        }
        // React to audioEnabled toggle
        .onChange(of: audioEnabled) { _, isEnabled in
            if isEnabled {
                if stream.state == .streaming {
                    connectAudioIfEnabled()
                }
                // else: will auto-connect when stream reaches .streaming
            } else {
                audio.disconnect()
            }
        }
        // Sync speaker volume
        .onChange(of: speakerVolume) { _, newValue in
            audio.speakerVolume = Float(newValue)
        }
        // Persist autoListen toggle from overlay
        .onChange(of: audio.autoListen) { _, newValue in
            autoListenOnConnect = newValue
        }
        // Sync stored value back to audio bridge
        .onChange(of: autoListenOnConnect) { _, newValue in
            audio.autoListen = newValue
        }
    }

    /// Connect audio bridge if enabled and a host is available.
    private func connectAudioIfEnabled() {
        guard audioEnabled, let host = espHost, !host.isEmpty else { return }
        audio.speakerVolume = Float(speakerVolume)
        audio.connect(to: host)
    }
}

#Preview {
    ContentView()
}
