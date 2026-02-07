import SwiftUI

@main
struct TasmotaCamViewerApp: App {

    init() {
        // Migrate stored camera URL to current default if it still
        // points to an old IP or path that no longer works.
        let stored = UserDefaults.standard.string(forKey: "cameraURL") ?? ""
        if stored.isEmpty || stored.contains("192.168.1.100") || stored.hasSuffix("/cam.mjpeg") {
            UserDefaults.standard.set(Constants.defaultStreamURL, forKey: "cameraURL")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
