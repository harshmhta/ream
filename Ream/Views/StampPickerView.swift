import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Picker for built-in stamps (Approved, Draft, …), dynamic stamps ({date}/
/// {user}/{time}), and custom image stamps. Choosing a stamp places it on the
/// current page via the ``ReamPDFView``.
struct StampPickerView: View {
    @ObservedObject var controller: AnnotationController
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stamps").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(StampLibrary.builtIns) { stamp in
                    Button {
                        place(stamp)
                    } label: {
                        stampPreview(stamp)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button {
                pickCustomImage()
            } label: {
                Label("Custom Image Stamp…", systemImage: "photo.badge.plus")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func stampPreview(_ stamp: StampLibrary.BuiltIn) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: StampLibrary.image(for: stamp))
                .resizable().scaledToFit()
                .frame(height: 32)
            if stamp.isDynamic {
                Text("dynamic").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func place(_ stamp: StampLibrary.BuiltIn) {
        let image = StampLibrary.image(for: stamp)
        let size = StampLibrary.suggestedSize(for: stamp)
        (controller.pdfView as? ReamPDFView)?.placeStamp(image: image, name: stamp.id, size: size)
        isPresented = false
    }

    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        // Scale to a reasonable placement size preserving aspect ratio.
        let maxDim: CGFloat = 160
        let scale = min(maxDim / max(image.size.width, 1), maxDim / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        (controller.pdfView as? ReamPDFView)?.placeStamp(
            image: image, name: url.deletingPathExtension().lastPathComponent, size: size)
        isPresented = false
    }
}
