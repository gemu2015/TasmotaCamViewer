import SwiftUI
import UserNotifications

/// Root view that wires together the camera stream, audio bridge, toolbar, settings, and status banner.
struct ContentView: View {
    @State private var stream = MJPEGStream()
    @State private var audio = AudioBridge()
    @State private var showSettings = false
    @State private var lightOn = false
    @State private var lightBusy = false

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

                // Ring indicator overlay (top)
                if audio.isRinging {
                    VStack {
                        HStack {
                            Image(systemName: "bell.fill")
                                .font(.title)
                                .foregroundStyle(.yellow)
                                .symbolEffect(.bounce, isActive: audio.isRinging)
                            Text("Doorbell!")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 60)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut, value: audio.isRinging)
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
                    lightOn: $lightOn,
                    showSettings: $showSettings,
                    onToggleLight: { toggleLight() }
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
            setupRingNotification()
            if autoConnect && !cameraURL.isEmpty {
                stream.connect(to: cameraURL)
                // audio connects once stream is up (see onChange of stream.state)
            }
        }
        // Start audio only after video stream is confirmed up
        .onChange(of: stream.state) { _, newState in
            if newState == .streaming {
                if audioEnabled && audio.state == .idle {
                    connectAudioIfEnabled()
                }
                queryLightState()
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

    /// Send a Tasmota command and update lightOn from the JSON response.
    private func sendTasmotaCommand(_ cmd: String) {
        guard let host = espHost, !host.isEmpty else { return }
        let urlStr = "http://\(host)/cm?cmnd=\(cmd)"
        guard let url = URL(string: urlStr) else { return }
        print("[Light] Sending: \(urlStr)")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let body = String(data: data, encoding: .utf8) ?? "nil"
                print("[Light] Response: \(body)")
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    let power = json["POWER"] ?? json["POWER1"]
                    if let power {
                        lightOn = (power == "ON")
                    }
                }
            } catch {
                print("[Light] Error: \(error)")
            }
            lightBusy = false
        }
    }

    /// Toggle the camera light via Tasmota Power command (debounced).
    private func toggleLight() {
        guard !lightBusy else { return }
        lightBusy = true
        sendTasmotaCommand("Power%20toggle")
    }

    /// Query current light state from Tasmota.
    private func queryLightState() {
        sendTasmotaCommand("Power")
    }

    /// Set up the doorbell ring callback and request notification permission.
    private func setupRingNotification() {
        // Request notification permission for background alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            print("[Ring] Notification permission: \(granted)")
        }

        audio.onRing = {
            sendLocalNotification()
        }
    }

    /// Send a local notification (works when app is in background).
    private func sendLocalNotification() {
        let content = UNMutableNotificationContent()
        content.title = "🔔 Doorbell"
        content.body = "Someone is at the camera"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "doorbell-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Ring] Notification error: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
}
