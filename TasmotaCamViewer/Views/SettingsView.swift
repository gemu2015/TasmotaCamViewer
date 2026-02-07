import SwiftUI

/// Camera configuration view with URL input, Tasmota presets, and audio settings.
struct SettingsView: View {
    @Binding var cameraURL: String
    @Binding var autoConnect: Bool
    @Binding var audioEnabled: Bool
    @Binding var speakerVolume: Double
    let onConnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var ipAddress: String = Constants.defaultIPAddress
    @State private var port: String = "81"

    private let presets: [(name: String, path: String, portNum: String)] = [
        ("MJPEG Stream", "/cam.mjpeg", "81"),
        ("Stream (alt)", "/stream", "81"),
        ("Cam JPG", "/cam.jpg", "81"),
        ("Diff Stream (motion)", "/diff.mjpeg", "81"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera Address") {
                    HStack {
                        Text("IP Address")
                            .frame(width: 90, alignment: .leading)
                        TextField("192.168.188.88", text: $ipAddress)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    HStack {
                        Text("Port")
                            .frame(width: 90, alignment: .leading)
                        TextField("81", text: $port)
                            .keyboardType(.numberPad)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Full Stream URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("http://192.168.188.88:81/stream", text: $cameraURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Section("Tasmota Presets") {
                    ForEach(presets, id: \.path) { preset in
                        Button {
                            port = preset.portNum
                            cameraURL = "http://\(ipAddress):\(preset.portNum)\(preset.path)"
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(":\(preset.portNum)\(preset.path)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fontDesign(.monospaced)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Section("Snapshot Endpoints (Port 80)") {
                    ForEach(Constants.tasmotaSnapshotEndpoints, id: \.self) { endpoint in
                        HStack {
                            Text(endpoint)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Single frame")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("Audio Intercom") {
                    Toggle("Enable Audio", isOn: $audioEnabled)

                    if audioEnabled {
                        HStack {
                            Text("Data Port")
                                .frame(width: 90, alignment: .leading)
                            Text("\(Constants.audioBridgeDataPort)")
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }

                        HStack {
                            Text("Control Port")
                                .frame(width: 90, alignment: .leading)
                            Text("\(Constants.audioBridgeControlPort)")
                                .foregroundStyle(.secondary)
                                .fontDesign(.monospaced)
                        }

                        HStack {
                            Text("Format")
                                .frame(width: 90, alignment: .leading)
                            Text("16 kHz / 16-bit / Stereo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Speaker Volume")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Image(systemName: "speaker.fill")
                                    .foregroundStyle(.secondary)
                                Slider(value: $speakerVolume, in: 0...1)
                                Image(systemName: "speaker.wave.3.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Auto-connect on launch", isOn: $autoConnect)
                }

                Section {
                    Button {
                        onConnect()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Connect", systemImage: "play.fill")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(cameraURL.isEmpty)
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                parseURLComponents()
            }
        }
    }

    /// Extract IP and port from the current URL for editing.
    private func parseURLComponents() {
        guard let url = URL(string: cameraURL),
              let host = url.host else { return }
        ipAddress = host
        if let urlPort = url.port {
            port = String(urlPort)
        }
    }
}
