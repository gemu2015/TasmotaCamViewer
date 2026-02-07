@preconcurrency import AVFoundation
import Foundation

/// Errors specific to AudioEngine operations.
enum AudioEngineError: LocalizedError {
    case invalidInputFormat

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone input format is invalid (0 Hz or 0 channels). Check audio session."
        }
    }
}

/// Unified audio engine for microphone capture and speaker playback.
final class AudioEngine {

    // MARK: - Properties

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// The wire format matching the Tasmota I2S bridge protocol.
    private let bridgeFormat: AVAudioFormat

    /// Ring buffer for incoming audio data.
    private let ringBuffer = RingBuffer(capacity: 64 * 1024)

    /// Converter from input hardware format to bridge format for capture.
    private var captureConverter: AVAudioConverter?
    private var captureResidue = Data()

    var onCapturedBuffer: ((Data) -> Void)?

    private var isCaptureActive = false
    private var isPlaybackActive = false
    private var playbackPacketCount: UInt64 = 0

    /// Playback gain multiplier (applied to incoming audio before scheduling).
    /// Default 4.0 boosts the typically low ESP32 mic signal.
    var playbackGain: Float = 4.0

    // MARK: - Init

    init() {
        bridgeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Constants.audioSampleRate,
            channels: AVAudioChannelCount(Constants.audioChannels),
            interleaved: true
        )!
    }

    // MARK: - Audio Session

    func configureSession(forPlaybackOnly: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        if forPlaybackOnly {
            try session.setCategory(.playback, options: [])
        } else {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        print("[AudioEngine] Session: category=\(session.category.rawValue), rate=\(session.sampleRate), route=\(session.currentRoute.outputs.map { $0.portName })")
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Microphone Permission

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Capture

    func startCapture() throws {
        guard !isCaptureActive else { return }

        try configureSession()

        if engine.isRunning { engine.stop() }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Input format: \(inputFormat)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.invalidInputFormat
        }

        captureConverter = AVAudioConverter(from: inputFormat, to: bridgeFormat)
        captureResidue.removeAll()

        let tapBufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.032)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { [weak self] buffer, _ in
            self?.processCapturedBuffer(buffer)
        }

        try engine.start()
        isCaptureActive = true
        print("[AudioEngine] Capture started")
    }

    func stopCapture() {
        guard isCaptureActive else { return }

        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        captureConverter = nil
        captureResidue.removeAll()
        isCaptureActive = false
        print("[AudioEngine] Capture stopped")

        stopEngineIfIdle()
    }

    // MARK: - Playback

    func startPlayback() throws {
        guard !isPlaybackActive else { return }

        try configureSession(forPlaybackOnly: true)

        if engine.isRunning { engine.stop() }

        // Attach player node
        if !engine.attachedNodes.contains(playerNode) {
            engine.attach(playerNode)
        }

        // Get the output hardware format AFTER configuring the session
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Output hardware format: \(outputFormat)")

        // Connect: playerNode → mainMixer using the output format
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        try engine.start()
        playerNode.play()

        isPlaybackActive = true
        playbackPacketCount = 0
        ringBuffer.reset()

        print("[AudioEngine] Playback started")
        print("[AudioEngine]   engine.isRunning=\(engine.isRunning) player.isPlaying=\(playerNode.isPlaying)")
        print("[AudioEngine]   mixer vol=\(engine.mainMixerNode.outputVolume) player vol=\(playerNode.volume)")
    }

    /// Accumulation buffer — collects incoming packets and schedules in larger chunks
    /// to avoid underruns from tiny individual buffers.
    private var accumulator = Data()
    private let accumulatorTarget = 4096 // accumulate ~4KB before scheduling (~64ms at 16kHz stereo)

    /// Enqueue raw PCM data (16 kHz, 16-bit, stereo interleaved) for speaker output.
    func enqueuePlayback(_ data: Data) {
        guard isPlaybackActive, !data.isEmpty else { return }

        playbackPacketCount += 1
        accumulator.append(data)

        // Don't schedule until we have enough data
        guard accumulator.count >= accumulatorTarget else { return }

        scheduleAccumulatedData()
    }

    /// Flush any remaining accumulated data (e.g., on stop).
    private func flushAccumulator() {
        if !accumulator.isEmpty && isPlaybackActive {
            scheduleAccumulatedData()
        }
    }

    private func scheduleAccumulatedData() {
        let chunk = accumulator
        accumulator = Data()

        let outputFormat = playerNode.outputFormat(forBus: 0)
        let hwRate = outputFormat.sampleRate
        let hwChannels = Int(outputFormat.channelCount)
        guard hwRate > 0, hwChannels > 0 else { return }

        let srcChannels = Int(Constants.audioChannels)
        let srcBytesPerFrame = srcChannels * 2
        let srcFrameCount = chunk.count / srcBytesPerFrame
        guard srcFrameCount > 0 else { return }

        let ratio = hwRate / Constants.audioSampleRate
        let dstFrameCount = Int(Double(srcFrameCount) * ratio)
        guard dstFrameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(dstFrameCount)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(dstFrameCount)

        let gain = playbackGain

        chunk.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.bindMemory(to: Int16.self).baseAddress else { return }
            guard let floatData = pcmBuffer.floatChannelData else { return }

            for dstFrame in 0..<dstFrameCount {
                let srcFrame = min(Int(Double(dstFrame) / ratio), srcFrameCount - 1)
                let srcIdx = srcFrame * srcChannels

                let leftSample = min(max(Float(src[srcIdx]) / 32768.0 * gain, -1.0), 1.0)
                floatData[0][dstFrame] = leftSample

                if hwChannels > 1 {
                    let rightSample = srcChannels > 1
                        ? min(max(Float(src[srcIdx + 1]) / 32768.0 * gain, -1.0), 1.0)
                        : leftSample
                    floatData[1][dstFrame] = rightSample
                }
            }
        }

        playerNode.scheduleBuffer(pcmBuffer)

        if playbackPacketCount <= 5 {
            print("[AudioEngine] Scheduled \(srcFrameCount)@16kHz → \(dstFrameCount)@\(hwRate)Hz, playing=\(playerNode.isPlaying)")
        }
    }

    func stopPlayback() {
        guard isPlaybackActive else { return }

        playerNode.stop()
        isPlaybackActive = false
        ringBuffer.reset()
        print("[AudioEngine] Playback stopped (total packets: \(playbackPacketCount))")

        stopEngineIfIdle()
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    // MARK: - Stop All

    func stopAll() {
        if engine.isRunning { engine.stop() }

        if isCaptureActive {
            engine.inputNode.removeTap(onBus: 0)
            captureConverter = nil
            captureResidue.removeAll()
            isCaptureActive = false
        }

        if isPlaybackActive {
            playerNode.stop()
            isPlaybackActive = false
        }

        ringBuffer.reset()
        deactivateSession()
        print("[AudioEngine] All stopped")
    }

    // MARK: - Private

    /// Schedule a sine wave test tone to verify audio output is working.
    private func scheduleSineTest(format: AVAudioFormat, durationSeconds: Double, frequency: Double) {
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            print("[AudioEngine] SINE TEST: Failed to create buffer")
            return
        }
        buffer.frameLength = frameCount

        guard let floatData = buffer.floatChannelData else {
            print("[AudioEngine] SINE TEST: No float channel data")
            return
        }

        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2.0 * Double.pi * frequency * Double(frame) / sampleRate)) * 0.5
            floatData[0][frame] = sample
            if channels > 1 {
                floatData[1][frame] = sample
            }
        }

        playerNode.scheduleBuffer(buffer) {
            print("[AudioEngine] SINE TEST: Finished playing")
        }
        print("[AudioEngine] SINE TEST: Scheduled \(frameCount) frames (\(durationSeconds)s) of \(frequency)Hz tone at \(sampleRate)Hz")
    }

    private func stopEngineIfIdle() {
        if !isCaptureActive && !isPlaybackActive && engine.isRunning {
            engine.stop()
            deactivateSession()
        }
    }

    private func processCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = captureConverter else { return }

        let ratio = Constants.audioSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: bridgeFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        nonisolated(unsafe) var allConsumed = false
        nonisolated(unsafe) let capturedBuffer = buffer

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return capturedBuffer
        }

        if let error {
            print("[AudioEngine] Conversion error: \(error)")
            return
        }

        guard convertedBuffer.frameLength > 0 else { return }

        let bytesPerFrame = Int(Constants.audioChannels) * (Constants.audioBitsPerSample / 8)
        let totalBytes = Int(convertedBuffer.frameLength) * bytesPerFrame

        var rawData = Data(count: totalBytes)
        rawData.withUnsafeMutableBytes { dst in
            if let src = convertedBuffer.int16ChannelData {
                memcpy(dst.baseAddress!, src[0], totalBytes)
            }
        }

        captureResidue.append(rawData)

        let packetSize = Constants.audioBridgeBufferSize
        while captureResidue.count >= packetSize {
            let packet = captureResidue.prefix(packetSize)
            onCapturedBuffer?(Data(packet))
            captureResidue.removeFirst(packetSize)
        }
    }
}

// MARK: - Ring Buffer

final class RingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var writePos: Int = 0
    private var readPos: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
    }

    deinit { buffer.deallocate() }

    var availableBytes: Int {
        let w = writePos, r = readPos
        return w >= r ? w - r : capacity - r + w
    }

    @discardableResult
    func write(from src: UnsafePointer<UInt8>, count: Int) -> Int {
        let available = capacity - availableBytes - 1
        let toWrite = min(count, available)
        guard toWrite > 0 else { return 0 }
        let w = writePos
        let firstChunk = min(toWrite, capacity - w)
        memcpy(buffer + w, src, firstChunk)
        if firstChunk < toWrite { memcpy(buffer, src + firstChunk, toWrite - firstChunk) }
        writePos = (w + toWrite) % capacity
        return toWrite
    }

    @discardableResult
    func read(into dst: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        let avail = availableBytes
        let toRead = min(count, avail)
        guard toRead > 0 else { return 0 }
        let r = readPos
        let firstChunk = min(toRead, capacity - r)
        memcpy(dst, buffer + r, firstChunk)
        if firstChunk < toRead { memcpy(dst + firstChunk, buffer, toRead - firstChunk) }
        readPos = (r + toRead) % capacity
        return toRead
    }

    func reset() { readPos = 0; writePos = 0 }
}
