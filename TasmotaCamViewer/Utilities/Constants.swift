import Foundation

enum Constants {
    // Known Tasmota ESP32-CAM boundary (hardcoded in xdrv_81_esp32_webcam_task.ino)
    static let defaultTasmotaBoundary = "e8b8c539-047d-4777-a985-fbba6edff11e"

    // Default stream URL
    static let defaultStreamURL = "http://192.168.188.88:81/stream"
    static let defaultIPAddress = "192.168.188.88"

    // Timeouts
    static let connectionTimeout: TimeInterval = 10.0

    // Reconnection
    static let maxReconnectAttempts = 20
    static let maxReconnectDelay: TimeInterval = 15.0
    static let initialReconnectDelay: TimeInterval = 1.0

    // FPS
    static let fpsUpdateInterval: TimeInterval = 2.0

    // Parser
    static let parserBufferInitialCapacity = 65_536 // 64KB

    // JPEG markers
    static let jpegSOI: [UInt8] = [0xFF, 0xD8]

    // Tasmota stream endpoint (port 81)
    static let tasmotaStreamPath = "/stream"

    // MARK: - Audio Bridge (UDP) — xdrv_42_5_i2s_bridge_idf51.ino

    /// UDP port for raw PCM audio data
    static let audioBridgeDataPort: UInt16 = 6970
    /// UDP port for text control commands (data port + 1)
    static let audioBridgeControlPort: UInt16 = 6971
    /// Max bytes per UDP audio packet (matches I2S_BRIDGE_BUFFER_SIZE)
    static let audioBridgeBufferSize: Int = 512

    /// Audio format: 16 kHz, 16-bit signed, stereo interleaved (dual-mono)
    static let audioSampleRate: Double = 16000.0
    static let audioChannels: UInt32 = 2
    static let audioBitsPerSample: Int = 16

    /// Control commands sent to port 6971
    static let audioCmdStop  = "cmd:0"  // Stop bridge
    static let audioCmdRead  = "cmd:1"  // ESP32 receives audio, plays on speaker
    static let audioCmdWrite = "cmd:2"  // ESP32 captures mic, sends audio via UDP
}
