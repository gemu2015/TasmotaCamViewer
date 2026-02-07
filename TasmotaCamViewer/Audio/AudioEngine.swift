import AVFoundation
import Foundation

/// Unified audio engine for microphone capture and speaker playback.
///
/// - Capture: taps the input node, resamples to 16 kHz 16-bit stereo-interleaved PCM,
///   chunks into 512-byte packets, and delivers via `onCapturedBuffer`.
/// - Playback: schedules received 16 kHz 16-bit stereo PCM buffers on an AVAudioPlayerNode.
final class AudioEngine {

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The target format matching the Tasmota I2S bridge protocol.
    private let bridgeFormat: AVAudioFormat

    /// Converter from bridge format to the output hardware format for playback.
    private var playbackConverter: AVAudioConverter?

    /// Converter from input hardware format to bridge format for capture.
    private var captureConverter: AVAudioConverter?

    /// Residual capture bytes not yet filling a full 512-byte packet.
    private var captureResidue = Data()

    /// Called with each 512-byte PCM packet captured from the microphone.
    var onCapturedBuffer: ((Data) -> Void)?

    private var isCaptureActive = false
    private var isPlaybackActive = false

    // MARK: - Init

    init() {
        // 16 kHz, 16-bit signed integer, 2 channels, interleaved
        bridgeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Constants.audioSampleRate,
            channels: AVAudioChannelCount(Constants.audioChannels),
            interleaved: true
        )!
    }

    // MARK: - Audio Session

    /// Configure the shared audio session for simultaneous capture and playback.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(Constants.audioSampleRate)
        try session.setPreferredIOBufferDuration(0.02) // 20ms buffer
        try session.setActive(true)
    }

    /// Deactivate the audio session.
    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Microphone Permission

    /// Request microphone permission. Returns `true` if granted.
    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Capture

    /// Start capturing microphone audio.
    /// Captured buffers are delivered via `onCapturedBuffer` as 512-byte PCM packets.
    func startCapture() throws {
        guard !isCaptureActive else { return }

        if !engine.isRunning {
            try configureSession()
            setupPlaybackGraph()
            try engine.start()
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Input format: \(inputFormat)")

        // Create converter: hardware mic format → 16kHz Int16 stereo
        captureConverter = AVAudioConverter(from: inputFormat, to: bridgeFormat)
        captureResidue.removeAll()

        // Tap buffer size: ~32ms worth of samples at the input sample rate
        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.032)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processCapturedBuffer(buffer)
        }

        isCaptureActive = true
        print("[AudioEngine] Capture started")
    }

    /// Stop capturing microphone audio.
    func stopCapture() {
        guard isCaptureActive else { return }

        engine.inputNode.removeTap(onBus: 0)
        captureConverter = nil
        captureResidue.removeAll()
        isCaptureActive = false
        print("[AudioEngine] Capture stopped")

        stopEngineIfIdle()
    }

    // MARK: - Playback

    /// Start the playback engine (prepares the player node).
    func startPlayback() throws {
        guard !isPlaybackActive else { return }

        if !engine.isRunning {
            try configureSession()
            setupPlaybackGraph()
            try engine.start()
        }

        playerNode.play()
        isPlaybackActive = true
        print("[AudioEngine] Playback started")
    }

    /// Enqueue raw PCM data (16 kHz, 16-bit, stereo interleaved) for speaker output.
    func enqueuePlayback(_ data: Data) {
        guard isPlaybackActive, !data.isEmpty else { return }

        // Convert raw bytes to AVAudioPCMBuffer in bridge format
        let frameCount = AVAudioFrameCount(data.count / (Int(Constants.audioChannels) * (Constants.audioBitsPerSample / 8)))
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: bridgeFormat, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy raw bytes into the buffer
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress else { return }
            if let dst = pcmBuffer.int16ChannelData {
                // Interleaved: single pointer, copy all bytes
                memcpy(dst[0], src, data.count)
            }
        }

        playerNode.scheduleBuffer(pcmBuffer)
    }

    /// Stop playback.
    func stopPlayback() {
        guard isPlaybackActive else { return }

        playerNode.stop()
        isPlaybackActive = false
        print("[AudioEngine] Playback stopped")

        stopEngineIfIdle()
    }

    /// Set the playback volume (0.0 – 1.0).
    var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }

    // MARK: - Stop All

    /// Stop everything and release the audio session.
    func stopAll() {
        if isCaptureActive { stopCapture() }
        if isPlaybackActive { stopPlayback() }
        if engine.isRunning { engine.stop() }
        deactivateSession()
    }

    // MARK: - Private

    /// Attach and connect the player node if not already done.
    private func setupPlaybackGraph() {
        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }
        // Connect player → mixer with the bridge format.
        // AVAudioEngine handles sample rate conversion to hardware format internally.
        engine.connect(playerNode, to: engine.mainMixerNode, format: bridgeFormat)
    }

    /// Stop the engine if neither capture nor playback is active.
    private func stopEngineIfIdle() {
        if !isCaptureActive && !isPlaybackActive && engine.isRunning {
            engine.stop()
            deactivateSession()
        }
    }

    /// Convert a captured buffer from hardware format to bridge format and chunk into 512-byte packets.
    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter else { return }

        // Calculate output frame count based on sample rate ratio
        let ratio = Constants.audioSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: bridgeFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[AudioEngine] Conversion error: \(error)")
            return
        }

        guard convertedBuffer.frameLength > 0 else { return }

        // Extract raw bytes from converted buffer
        let bytesPerFrame = Int(Constants.audioChannels) * (Constants.audioBitsPerSample / 8) // 4 bytes
        let totalBytes = Int(convertedBuffer.frameLength) * bytesPerFrame

        var rawData = Data(count: totalBytes)
        rawData.withUnsafeMutableBytes { dst in
            if let src = convertedBuffer.int16ChannelData {
                memcpy(dst.baseAddress!, src[0], totalBytes)
            }
        }

        // Append to residue and chunk into 512-byte packets
        captureResidue.append(rawData)

        let packetSize = Constants.audioBridgeBufferSize
        while captureResidue.count >= packetSize {
            let packet = captureResidue.prefix(packetSize)
            onCapturedBuffer?(Data(packet))
            captureResidue.removeFirst(packetSize)
        }
    }
}
