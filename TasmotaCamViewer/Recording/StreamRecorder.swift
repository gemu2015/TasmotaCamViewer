import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Records the camera stream (MJPEG frames + the 16 kHz PCM from the camera microphone) into an MP4 file
/// (H.264 + AAC). This file is identical in the iOS and the Mac project.
///
/// Frames and audio packets are time-stamped with the arrival time (monotonic clock), the audio
/// additionally with a sample counter so it stays gapless; a gap in the packets (loss, push-to-talk) is
/// kept as a gap instead of shifting everything after it.
@Observable
final class StreamRecorder: @unchecked Sendable {

    // MARK: - Observable state (main thread)

    private(set) var isRecording = false
    private(set) var startDate: Date?
    /// File of the last finished recording (shown in the "saved" banner).
    var lastFileURL: URL?
    var lastError: String?

    // MARK: - Writer state (only touched on `queue`)

    @ObservationIgnored private let queue = DispatchQueue(label: "StreamRecorder.queue", qos: .userInitiated)
    @ObservationIgnored private var writer: AVAssetWriter?
    @ObservationIgnored private var videoInput: AVAssetWriterInput?
    @ObservationIgnored private var audioInput: AVAssetWriterInput?
    @ObservationIgnored private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var t0: CFTimeInterval = 0          // host time of the first video frame
    @ObservationIgnored private var lastVideoMs: Int64 = -1
    @ObservationIgnored private var width = 0
    @ObservationIgnored private var height = 0
    @ObservationIgnored private var audioBase: Double = 0
    @ObservationIgnored private var audioSamples: Int64 = 0
    @ObservationIgnored private var audioFormat: CMAudioFormatDescription?

    private static let audioRate: Double = 16000

    // MARK: - Public

    /// Folder the recordings go to: Files app > TasmotaCam (iOS), ~/Movies/TasmotaCam (Mac).
    static func recordingsDirectory() -> URL {
        let fm = FileManager.default
        #if os(iOS)
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        #else
        let base = fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TasmotaCam", isDirectory: true)
        #endif
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Start a recording. The file is created when the first video frame arrives (it needs the size).
    func start() {
        guard !isRecording else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.recordingsDirectory().appendingPathComponent("TasmotaCam_\(f.string(from: Date())).mp4")
        isRecording = true
        startDate = Date()
        lastError = nil
        queue.async {
            self.fileURL = url
            self.writer = nil
            self.lastVideoMs = -1
            self.audioSamples = 0
            self.active = true
        }
    }

    /// Stop and finish the file. `lastFileURL` is set when it is playable.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        startDate = nil
        queue.async {
            self.active = false
            guard let writer = self.writer, let url = self.fileURL else {
                DispatchQueue.main.async { self.lastError = "No video frame arrived, nothing was recorded." }
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer = nil
            writer.finishWriting {
                let failed = writer.status != .completed
                let message = writer.error?.localizedDescription
                DispatchQueue.main.async {
                    if failed {
                        self.lastError = message ?? "Recording failed"
                    } else {
                        self.lastFileURL = url
                    }
                }
            }
        }
    }

    /// Add a camera frame (called for every decoded frame).
    func appendVideo(_ image: CGImage) {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        queue.async {
            guard self.active else { return }
            if self.writer == nil { self.setupWriter(first: image, now: now) }
            guard self.writer != nil, let input = self.videoInput, let adaptor = self.adaptor,
                  input.isReadyForMoreMediaData else { return }
            let ms = Int64((now - self.t0) * 1000)
            guard ms > self.lastVideoMs else { return }
            guard let buffer = self.pixelBuffer(from: image, adaptor: adaptor) else { return }
            if adaptor.append(buffer, withPresentationTime: CMTime(value: ms, timescale: 1000)) {
                self.lastVideoMs = ms
            }
        }
    }

    /// Add a received audio packet: 16 kHz, 16 bit signed, stereo interleaved (dual mono) as the I2S bridge sends it.
    func appendAudio(_ data: Data, gain: Float) {
        guard isRecording, data.count >= 4 else { return }
        let now = CACurrentMediaTime()
        queue.async {
            guard self.active, self.writer != nil, let input = self.audioInput,
                  input.isReadyForMoreMediaData, let format = self.audioFormat else { return }
            let frames = data.count / 4
            var mono = [Int16](repeating: 0, count: frames)
            data.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: Int16.self)
                for i in 0..<frames {
                    let v = (Float(s[2 * i]) + Float(s[2 * i + 1])) * 0.5 * gain
                    mono[i] = Int16(max(-32768, min(32767, v)))
                }
            }
            let rel = now - self.t0
            if rel < 0 { return }
            if self.audioSamples == 0 {
                self.audioBase = rel
            } else {
                let expected = self.audioBase + Double(self.audioSamples) / Self.audioRate
                if rel - expected > 0.25 { self.audioBase = rel - Double(self.audioSamples) / Self.audioRate }
            }
            let pts = CMTime(seconds: self.audioBase + Double(self.audioSamples) / Self.audioRate, preferredTimescale: 16000)
            if let sb = Self.sampleBuffer(mono: mono, format: format, pts: pts) {
                if input.append(sb) { self.audioSamples += Int64(frames) }
            }
        }
    }

    // MARK: - Private (queue)

    private func setupWriter(first image: CGImage, now: CFTimeInterval) {
        guard let url = fileURL else { return }
        width = max(2, image.width & ~1)
        height = max(2, image.height & ~1)
        try? FileManager.default.removeItem(at: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let vSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(1_500_000, width * height * 3),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: 15,
                    AVVideoMaxKeyFrameIntervalKey: 60,
                ],
            ]
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: v,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Self.audioRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var fmt: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                           formatDescriptionOut: &fmt)
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.audioRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000,   // AAC at 16 kHz mono refuses >= 56 kbit/s (-11861)
            ]
            let au = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            au.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(au) else { throw NSError(domain: "StreamRecorder", code: 1) }
            w.add(v)
            w.add(au)
            guard w.startWriting() else { throw w.error ?? NSError(domain: "StreamRecorder", code: 2) }
            w.startSession(atSourceTime: .zero)
            writer = w
            videoInput = v
            audioInput = au
            adaptor = a
            audioFormat = fmt
            t0 = now
        } catch {
            active = false
            let msg = error.localizedDescription
            DispatchQueue.main.async {
                self.isRecording = false
                self.startDate = nil
                self.lastError = msg
            }
        }
    }

    private func pixelBuffer(from image: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
        }
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))   // scales if the size ever changes
        return buffer
    }

    private static func sampleBuffer(mono: [Int16], format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let bytes = mono.count * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let status = mono.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: mono.count,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

// MARK: - Platform image -> CGImage

#if canImport(UIKit)
extension UIImage {
    var recordingCGImage: CGImage? { cgImage }
}
#elseif canImport(AppKit)
extension NSImage {
    var recordingCGImage: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
#endif
