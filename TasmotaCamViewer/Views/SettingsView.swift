import SwiftUI

/// Camera configuration view with URL input, Tasmota presets, and audio settings.
struct SettingsView: View {
    @Binding var cameraURL: String
    @Binding var autoConnect: Bool
    @Binding var audioEnabled: Bool
    @Binding var speakerVolume: Double
    let onConnect: () -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage("cameraIPs") private var cameraIPsJSON: String = "[\"\(Constants.defaultIPAddress)\",\"\",\"\"]"
    @AppStorage("selectedIPIndex") private var selectedIPIndex: Int = 0

    @State private var ips: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera Address") {
                    ForEach(0..<3, id: \.self) { index in
                        HStack {
                            Button {
                                selectedIPIndex = index
                                applySelectedIP()
                                saveIPs()
                            } label: {
                                Image(systemName: selectedIPIndex == index ? "circle.fill" : "circle")
                                    .foregroundStyle(selectedIPIndex == index ? .blue : .secondary)
                            }
                            .buttonStyle(.plain)

                            Text("Cam \(index + 1)")
                                .frame(width: 50, alignment: .leading)

                            TextField("IP Address", text: binding(for: index))
                                .keyboardType(.decimalPad)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .fontDesign(.monospaced)
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
                        saveIPs()
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
                    Button("Done") {
                        saveIPs()
                        onConnect()
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadIPs()
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { index < ips.count ? ips[index] : "" },
            set: { newValue in
                while ips.count <= index { ips.append("") }
                ips[index] = newValue
                if index == selectedIPIndex {
                    applySelectedIP()
                }
                saveIPs()
            }
        )
    }

    private func loadIPs() {
        if let data = cameraIPsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            ips = decoded
        }
        while ips.count < 3 { ips.append("") }
    }

    private func saveIPs() {
        while ips.count < 3 { ips.append("") }
        if let data = try? JSONEncoder().encode(Array(ips.prefix(3))),
           let json = String(data: data, encoding: .utf8) {
            cameraIPsJSON = json
        }
    }

    private func applySelectedIP() {
        guard selectedIPIndex < ips.count else { return }
        let ip = ips[selectedIPIndex]
        guard !ip.isEmpty else { return }
        cameraURL = "http://\(ip):81\(Constants.tasmotaStreamPath)"
    }
}
