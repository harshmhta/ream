import SwiftUI
import UniformTypeIdentifiers
import ReamCore

/// The **New from Images** sheet: reorder the chosen images, pick a page size,
/// and produce either one combined PDF or one PDF per image (batch mode).
struct ImagesToPDFSheet: View {
    @ObservedObject var coordinator: ConversionCoordinator

    @State private var pageSize: PageSizeOption = .fitImage
    @State private var batchMode = false
    @State private var errorMessage: String?
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.isRunning {
                ConversionProgressView(progress: coordinator.progress) { coordinator.cancel() }
            } else {
                content
            }
        }
        .frame(width: 480, height: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("New PDF from Images").font(.headline)
                Text("\(coordinator.pendingImageURLs.count) image\(coordinator.pendingImageURLs.count == 1 ? "" : "s") · drag to reorder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            imageList

            HStack {
                Button {
                    coordinator.addMoreImages()
                } label: {
                    Label("Add Images…", systemImage: "plus")
                }
                Button(role: .destructive) {
                    coordinator.pendingImageURLs.removeAll { selection.contains($0) }
                    selection.removeAll()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)

            Divider()

            Picker("Page size", selection: $pageSize) {
                ForEach(PageSizeOption.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Save each image as its own PDF (batch)", isOn: $batchMode)
                .font(.callout)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(20)
    }

    private var imageList: some View {
        List(selection: $selection) {
            ForEach(coordinator.pendingImageURLs, id: \.self) { url in
                HStack(spacing: 10) {
                    ImageThumbnail(url: url)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1)
                        Text(url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                }
                .tag(url)
            }
            .onMove { indices, newOffset in
                coordinator.pendingImageURLs.move(fromOffsets: indices, toOffset: newOffset)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 200)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { coordinator.dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(batchMode ? "Create PDFs…" : "Create PDF…") {
                Task { await run() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(coordinator.pendingImageURLs.isEmpty)
        }
    }

    // MARK: Run

    private func run() async {
        errorMessage = nil
        let urls = coordinator.pendingImageURLs
        let size = pageSize
        do {
            if batchMode {
                try await runBatch(urls: urls, size: size)
            } else {
                try await runCombined(urls: urls, size: size)
            }
        } catch let error as ConversionError where error == .cancelled {
            // silent
        } catch {
            errorMessage = (error as? ConversionError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runCombined(urls: [URL], size: PageSizeOption) async throws {
        let data = try await coordinator.run { progress, token in
            try ImagesToPDFConverter.makePDF(imageURLs: urls, pageSize: size,
                                             progress: progress, cancellation: token)
        }
        guard let dest = coordinator.chooseSaveURL(suggestedName: "Images.pdf", contentType: .pdf) else { return }
        try data.write(to: dest, options: .atomic)
        coordinator.dismiss()
        coordinator.openInNewWindow(dest)
    }

    private func runBatch(urls: [URL], size: PageSizeOption) async throws {
        let items = try await coordinator.run { progress, token in
            try ImagesToPDFConverter.makeBatch(imageURLs: urls, pageSize: size,
                                               progress: progress, cancellation: token)
        }
        guard let folder = coordinator.chooseDirectory(message: "Choose a folder for the PDFs") else { return }
        try coordinator.writeFiles(items.map { ("\($0.nameStem).pdf", $0.data) }, into: folder)
        coordinator.dismiss()
    }
}

/// A small async thumbnail for the image reorder list, rendered via ImageIO so
/// large photos don't load full-size into memory.
private struct ImageThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: url) {
            image = await Self.thumbnail(for: url)
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 80,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }
}
