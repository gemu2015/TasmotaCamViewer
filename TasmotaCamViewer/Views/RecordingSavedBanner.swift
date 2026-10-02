import SwiftUI

/// Shown after a recording was finished: file name, share button (Files app > TasmotaCam holds the file).
struct RecordingSavedBanner: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording saved").font(.subheadline.bold())
                Text(url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }
}
