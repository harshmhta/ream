import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReamCore

/// Per-window coordinator for the Convert & Export features (compress,
/// images → PDF, PDF → images).
///
/// It owns which conversion sheet is showing, runs the (synchronous, CPU-heavy)
/// `ReamCore` engines off the main actor with live progress + cooperative
/// cancel, and hosts the NSOpenPanel / NSSavePanel plumbing. Menu commands and
/// ⌘K palette commands drive it via `@FocusedValue`, mirroring how zoom drives
/// ``PDFViewCoordinator``.
@MainActor
final class ConversionCoordinator: ObservableObject {

    /// The coordinator belonging to the most recently focused document window.
    ///
    /// The ⌘K palette is a single app-wide singleton whose commands are plain
    /// closures, so — unlike the menu bar, which reads `@FocusedValue` — it has no
    /// built-in notion of "the focused window". Rather than have each window
    /// register window-specific closures (which fight over shared command ids and
    /// can act on the wrong or a closed window), palette commands are registered
    /// once and route through this pointer, which every window updates when it
    /// appears/becomes active. Weak so a closed window's coordinator is released.
    weak static var active: ConversionCoordinator?

    /// Which modal sheet is currently presented, if any.
    enum ActiveSheet: String, Identifiable {
        case compress
        case imagesToPDF
        case pdfToImages
        var id: String { rawValue }
    }

    @Published var activeSheet: ActiveSheet?

    /// Live progress of the running operation (nil when idle).
    @Published private(set) var progress: ConversionProgress?
    @Published private(set) var isRunning = false

    /// Images chosen for an Images → PDF run, in page order (edited in the sheet).
    @Published var pendingImageURLs: [URL] = []

    /// The document this coordinator serves (for compress / PDF → images). Weak so
    /// a closed window's document is released.
    weak var document: PDFReferenceDocument?

    /// A short title used to seed suggested output file names.
    var documentTitle: String = "Document"

    private var cancellation: CancellationToken?

    // MARK: - Presenting sheets

    func presentCompress() {
        guard document?.pdfDocument.pageCount ?? 0 > 0 else { return }
        activeSheet = .compress
    }

    func presentPDFToImages() {
        guard document?.pdfDocument.pageCount ?? 0 > 0 else { return }
        activeSheet = .pdfToImages
    }

    /// Prompt for images, then present the reorder/convert sheet if any chosen.
    /// Replaces the pending list — this is the entry point (menu / palette).
    func presentImagesToPDF() {
        guard let picked = chooseImages() else { return }
        pendingImageURLs = picked
        activeSheet = .imagesToPDF
    }

    /// Append more images to the pending list from within the open sheet, keeping
    /// existing order and skipping duplicates. Used by the sheet's "Add Images…".
    func addMoreImages() {
        guard let picked = chooseImages() else { return }
        let existing = Set(pendingImageURLs)
        pendingImageURLs.append(contentsOf: picked.filter { !existing.contains($0) })
    }

    /// Run the image open panel; returns the chosen URLs, or nil if cancelled.
    private func chooseImages() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif, .image]
        panel.message = "Choose images to combine into a PDF"
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }

    func dismiss() {
        activeSheet = nil
    }

    // MARK: - Source data

    /// Whether there is a document with data to convert. Cheap (no serialization).
    var hasDocumentData: Bool {
        (document?.pdfDocument.pageCount ?? 0) > 0
    }

    /// The current document's PDF bytes (source for compress / export).
    ///
    /// `PDFDocument.dataRepresentation()` re-serializes the whole file, which is
    /// slow for large PDFs — so it runs off the main actor to avoid freezing the
    /// UI before the progress sheet appears. Returns nil if there is no document.
    func currentPDFData() async -> Data? {
        guard let pdf = document?.pdfDocument else { return nil }
        // `nonisolated(unsafe)`: PDFKit's PDFDocument isn't Sendable, but the
        // document is not mutated during a conversion, so reading its bytes on a
        // background thread is safe here.
        nonisolated(unsafe) let doc = pdf
        return await Task.detached(priority: .userInitiated) {
            doc.dataRepresentation()
        }.value
    }

    // MARK: - Running engines with progress + cancel

    /// Monotonic run id. Progress callbacks carry the id of the run that emitted
    /// them; a late/out-of-order callback from a finished run is ignored, so it
    /// can't resurrect a stale `progress` after the run's `defer` cleared it.
    private var runGeneration = 0

    /// Run a synchronous engine call off the main actor, publishing progress and
    /// honoring cancel. Returns the result or throws (including `.cancelled`).
    func run<T: Sendable>(
        _ work: @escaping @Sendable (@escaping ProgressHandler, CancellationToken) throws -> T
    ) async throws -> T {
        let token = CancellationToken()
        cancellation = token
        runGeneration &+= 1
        let generation = runGeneration
        isRunning = true
        progress = ConversionProgress(fraction: 0, message: "Starting…")
        defer {
            isRunning = false
            progress = nil
            cancellation = nil
        }

        // Progress callbacks arrive on a background queue; hop to main to publish,
        // but only while this exact run is the current one.
        let handler: ProgressHandler = { [weak self] update in
            Task { @MainActor in
                guard let self, self.runGeneration == generation, self.isRunning else { return }
                self.progress = update
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            try work(handler, token)
        }.value
    }

    /// Cancel the running operation, if any.
    func cancel() {
        cancellation?.cancel()
    }

    // MARK: - Save / open panels

    /// Ask where to save a single output file. Returns nil if cancelled.
    func chooseSaveURL(suggestedName: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Ask for an output directory. Returns nil if cancelled.
    func chooseDirectory(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Choose Folder"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Open a produced file in a new Ream window (used after Images → PDF so the
    /// result is immediately viewable).
    func openInNewWindow(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    /// Reveal produced file(s) in Finder — the shared "show me the output" step
    /// after a save completes.
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Write several named blobs into `folder`, sanitizing names and uniquing any
    /// collisions (so two source images called "scan" don't clobber each other),
    /// then reveal the results in Finder. Returns the URLs actually written.
    @discardableResult
    func writeFiles(_ files: [(name: String, data: Data)], into folder: URL) throws -> [URL] {
        var used = Set<String>()
        var written: [URL] = []
        for file in files {
            let safe = FileNaming.unique(FileNaming.sanitized(file.name), in: &used)
            let dest = folder.appendingPathComponent(safe)
            try file.data.write(to: dest, options: .atomic)
            written.append(dest)
        }
        revealInFinder(written)
        return written
    }

    /// A filesystem-safe stem from the current document title.
    var suggestedStem: String {
        let base = (documentTitle as NSString).deletingPathExtension
        return FileNaming.sanitized(base, fallback: "Document")
    }
}
