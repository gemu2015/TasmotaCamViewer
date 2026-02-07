import Foundation
import UIKit
import SwiftUI

/// Main ViewModel for the MJPEG camera stream.
/// Manages connection lifecycle, reconnection, FPS tracking, and snapshot capture.
@Observable
final class MJPEGStream {

    // MARK: - Published State

    /// The most recent decoded camera frame.
    var currentFrame: UIImage?

    /// Current connection state.
    var state: StreamState = .disconnected

    /// Current frames-per-second.
    var fps: Double = 0.0

    /// Last captured snapshot image (triggers sheet presentation).
    var lastSnapshot: UIImage?

    /// Whether the snapshot sheet is presented.
    var showSnapshot = false

    // MARK: - Private

    private let client = MJPEGStreamClient()
    private var streamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    // FPS tracking
    private var frameCount: Int = 0
    private var fpsTimerStart: Date = Date()

    // Reconnection
    private var reconnectAttempt: Int = 0
    private var currentURL: String = ""

    // MARK: - Lifecycle

    deinit {
        streamTask?.cancel()
        reconnectTask?.cancel()
        client.cancel()
    }

    // MARK: - Public Methods

    /// Connect to the given MJPEG stream URL.
    func connect(to urlString: String) {
        disconnect()

        currentURL = urlString
        reconnectAttempt = 0

        guard let url = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        startStreaming(url: url)
    }

    /// Disconnect from the current stream.
    func disconnect() {
        streamTask?.cancel()
        streamTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        client.cancel()

        currentFrame = nil
        state = .disconnected
        fps = 0.0
        frameCount = 0
    }

    /// Manually trigger a reconnection attempt.
    func reconnect() {
        guard !currentURL.isEmpty else { return }
        reconnectAttempt = 0
        connect(to: currentURL)
    }

    /// Capture the current frame as a snapshot.
    func takeSnapshot() {
        guard let frame = currentFrame else { return }
        lastSnapshot = frame
        showSnapshot = true
    }

    // MARK: - Private Methods

    private func startStreaming(url: URL) {
        state = .connecting
        frameCount = 0
        fpsTimerStart = Date()

        let eventStream = client.stream(from: url)

        streamTask = Task { @MainActor [weak self] in
            for await event in eventStream {
                guard let self, !Task.isCancelled else { break }

                switch event {
                case .frame(let image):
                    self.handleFrame(image)

                case .error(let error):
                    self.handleError(error)

                case .completed:
                    self.state = .disconnected
                }
            }
        }
    }

    private func handleFrame(_ image: UIImage) {
        currentFrame = image
        frameCount += 1

        // Update state to streaming on first frame
        if state != .streaming {
            state = .streaming
            reconnectAttempt = 0  // Reset on successful connection
        }

        // Update FPS periodically
        let elapsed = Date().timeIntervalSince(fpsTimerStart)
        if elapsed >= Constants.fpsUpdateInterval {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            fpsTimerStart = Date()
        }
    }

    private func handleError(_ error: StreamError) {
        state = .error(error.localizedDescription)
        fps = 0.0

        // Attempt auto-reconnection
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectAttempt < Constants.maxReconnectAttempts else {
            state = .error("Connection lost. Tap Retry to reconnect.")
            return
        }

        reconnectAttempt += 1
        let delay = min(
            Constants.initialReconnectDelay * pow(2.0, Double(reconnectAttempt - 1)),
            Constants.maxReconnectDelay
        )

        state = .reconnecting(attempt: reconnectAttempt)

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))

            guard let self, !Task.isCancelled else { return }
            guard let url = URL(string: self.currentURL) else { return }

            self.startStreaming(url: url)
        }
    }
}
