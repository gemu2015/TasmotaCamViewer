import SwiftUI

/// Sheet view for previewing and sharing a captured snapshot.
struct SnapshotPreviewSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 8)
                    .padding(.horizontal, 24)

                // Image info
                HStack(spacing: 24) {
                    Label(
                        "\(Int(image.size.width)) x \(Int(image.size.height))",
                        systemImage: "rectangle.dashed"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let data = image.jpegData(compressionQuality: 0.9) {
                        Label(
                            formatBytes(data.count),
                            systemImage: "doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Share button
                ShareLink(
                    item: TransferableImage(image: image),
                    preview: SharePreview("Camera Snapshot", image: Image(uiImage: image))
                ) {
                    Label("Share Snapshot", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Save to Photos
                Button {
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                } label: {
                    Label("Save to Photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()
                    .frame(height: 20)
            }
            .navigationTitle("Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
    }
}

// MARK: - Transferable Image for ShareLink

struct TransferableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { item in
            guard let data = item.image.jpegData(compressionQuality: 0.9) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
}
