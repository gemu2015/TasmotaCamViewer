import SwiftUI

/// Main view that displays the live camera frame.
struct CameraStreamView: View {
    let stream: MJPEGStream

    var body: some View {
        GeometryReader { geometry in
            if let frame = stream.currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: geometry.size.width,
                        maxHeight: geometry.size.height
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
            } else {
                placeholderView
                    .frame(
                        maxWidth: geometry.size.width,
                        maxHeight: geometry.size.height
                    )
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )
            }
        }
    }

    @ViewBuilder
    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: placeholderIcon)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: stream.state == .connecting || stream.state.isActive)

            Text(stream.state.statusText)
                .font(.title3)
                .foregroundStyle(.secondary)

            if stream.state == .connecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
            }
        }
    }

    private var placeholderIcon: String {
        switch stream.state {
        case .disconnected:
            return "video.slash"
        case .connecting, .reconnecting:
            return "antenna.radiowaves.left.and.right"
        case .streaming:
            return "video"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}
