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
                            .onChange(of: ipAddress) {
                                cameraURL = "http://\(ipAddress):81\(Constants.tasmotaStreamPath)"
                            }
                    }

                    HStack {
                        Text("Stream URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(cameraURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
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

    /// Extract IP from the current URL for editing.
    private func parseURLComponents() {
        guard let url = URL(string: cameraURL),
              let host = url.host else { return }
        ipAddress = host
    }
}
