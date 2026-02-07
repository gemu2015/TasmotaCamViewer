import SwiftUI

/// Overlay banner that shows connection status (connecting, reconnecting, error).
struct ConnectionStatusBanner: View {
    let state: StreamState
    let onRetry: () -> Void

    var body: some View {
        VStack {
            switch state {
            case .connecting:
                bannerView(
                    text: "Connecting...",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .orange,
                    showProgress: true
                )

            case .reconnecting(let attempt):
                bannerView(
                    text: "Reconnecting (attempt \(attempt))...",
                    icon: "arrow.clockwise",
                    color: .orange,
                    showProgress: true
                )

            case .error(let message):
                VStack(spacing: 8) {
                    bannerView(
                        text: message,
                        icon: "exclamationmark.triangle",
                        color: .red,
                        showProgress: false
                    )
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                }

            case .streaming, .disconnected:
                EmptyView()
            }

            Spacer()
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.3), value: state)
    }

    @ViewBuilder
    private func bannerView(text: String, icon: String, color: Color, showProgress: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)

            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)

            if showProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
