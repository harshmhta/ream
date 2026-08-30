import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers
import ReamCore

// Page ops share ``ReamCore/CancellationToken`` with the conversion engines: the
// UI (main actor) calls `cancel()`, the worker polls `isCancelled` from its
// background queue, and an internal lock keeps that cross-thread access race-free.

/// State driving the progress panel shown for operations that may exceed ~1s.
struct OperationProgress {
    var title: String
    /// 0…1 completion. Ignored when ``isIndeterminate`` is `true`.
    var fraction: Double = 0
    var isIndeterminate: Bool = false
}

/// Per-window controller for page & document operations.
///
/// Owns everything the pure ``PageOperations`` core cannot: file open/save
/// panels, background scheduling with a progress panel + cancel, which modal
/// sheet is showing, and registration of the ops into the ⌘K palette. Menus and
/// the palette reach the key window's instance via `@FocusedValue(\.pageOps)`.
///
/// Heavy work always runs from **`Data`** (either files freshly read from disk,
/// or a `dataRepresentation()` snapshot of the current document taken on the main
/// actor), never by sharing live `PDFPage` objects across threads — PDFKit is
/// not thread-safe, and this keeps all shared mutable state on one queue.
@MainActor
final class PageOpsController: ObservableObject {

    /// Which modal is presented over the document window.
    enum Sheet: Int, Identifiable {
        case managePages, merge, split, insert
        var id: Int { rawValue }
    }

    @Published var activeSheet: Sheet?
    /// Non-nil while a background operation runs; drives the progress panel.
    @Published var progress: OperationProgress?
    /// A transient user-facing error to surface in an alert.
    @Published var errorMessage: String?

    let document: PDFReferenceDocument
    weak var coordinator: PDFViewCoordinator?
    /// The window's undo manager (from `@Environment(\.undoManager)`), kept
    /// current by the hosting view so menu/palette ops register undo correctly.
    var undoManager: UndoManager?

    private var activeToken: CancellationToken?

    init(document: PDFReferenceDocument) {
        self.document = document
    }

    // MARK: - Sheet presentation

    func showManagePages() { activeSheet = .managePages }
    func showMerge() { activeSheet = .merge }
    func showSplit() { activeSheet = .split }
    func showInsert() { activeSheet = .insert }

    // MARK: - Background runner

    /// Run `work` off the main actor with a progress panel + cancel button.
    ///
    /// `work` receives a cancellation token to poll and a progress reporter
    /// (safe to call from the background — it hops to the main actor). The
    /// result is delivered back on the main actor via `completion`.
    func runInBackground<T>(
        title: String,
        indeterminate: Bool = false,
        work: @escaping (CancellationToken, @escaping (Double) -> Void) throws -> T,
        completion: @escaping (T) -> Void
    ) {
        let token = CancellationToken()
        activeToken = token
        progress = OperationProgress(title: title, isIndeterminate: indeterminate)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report: (Double) -> Void = { fraction in
                DispatchQueue.main.async {
                    self?.progress?.fraction = fraction
                }
            }
            do {
                let value = try work(token, report)
                DispatchQueue.main.async {
                    self?.finishOperation()
                    guard !token.isCancelled else { return }
                    completion(value)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishOperation()
                    if case PageOperations.OperationError.cancelled = error { return }
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Cancel the in-flight background operation, if any.
    func cancelCurrentOperation() {
        activeToken?.cancel()
    }

    private func finishOperation() {
        progress = nil
        activeToken = nil
    }

    // MARK: - Merge

    /// Merge `urls` (plus, optionally, the current document first) into a new
    /// file chosen via a save panel.
    func performMerge(urls: [URL], interleave: Bool, includeCurrent: Bool) {
        guard let output = runSavePanel(defaultName: "Merged.pdf") else { return }
        let currentData = includeCurrent ? document.pdfDocument.dataRepresentation() : nil

        runInBackground(title: "Merging PDFs…", work: { token, report in
            var docs: [PDFDocument] = []
            if let currentData, let doc = PDFDocument(data: currentData) { docs.append(doc) }
            for url in urls {
                if token.isCancelled { throw PageOperations.OperationError.cancelled }
                if let doc = PDFDocument(url: url) { docs.append(doc) }
            }
            let merged = try PageOperations.merge(docs, interleave: interleave,
                                                  isCancelled: { token.isCancelled },
                                                  onProgress: report)
            guard merged.write(to: output) else { throw PageOperations.OperationError.emptyResult }
            return output
        }, completion: { [weak self] written in
            self?.revealInFinder(written)
        })
    }

    // MARK: - Split

    /// Split the current document using `mode`, writing one file per part into a
    /// user-chosen directory.
    func performSplit(mode: SplitMode) {
        guard let directory = runDirectoryPanel() else { return }
        let baseName = (document.pdfDocument.documentURL?.deletingPathExtension().lastPathComponent) ?? "Split"
        guard let data = document.pdfDocument.dataRepresentation() else {
            errorMessage = "Could not read the current document."
            return
        }

        runInBackground(title: "Splitting…", work: { token, report in
            guard let source = PDFDocument(data: data) else { throw PageOperations.OperationError.emptyResult }
            let parts: [PDFDocument]
            switch mode {
            case .ranges(let spec): parts = try PageOperations.split(source, ranges: spec)
            case .everyN(let n): parts = try PageOperations.split(source, everyN: n)
            case .bookmarks:
                parts = PageOperations.splitByBookmarks(source)
                guard !parts.isEmpty else { throw PageOperations.OperationError.invalidRange("no top-level bookmarks") }
            }
            var written: [URL] = []
            for (i, part) in parts.enumerated() {
                if token.isCancelled { throw PageOperations.OperationError.cancelled }
                guard part.pageCount > 0 else { continue }
                let url = directory.appendingPathComponent("\(baseName)-\(i + 1).pdf")
                if part.write(to: url) { written.append(url) }
                report(Double(i + 1) / Double(parts.count))
            }
            guard !written.isEmpty else { throw PageOperations.OperationError.emptyResult }
            return directory
        }, completion: { [weak self] dir in
            self?.revealInFinder(dir)
        })
    }

    enum SplitMode {
        case ranges(String)
        case everyN(Int)
        case bookmarks
    }

    // MARK: - Extract

    /// Extract the given page indices from the current document into a new file.
    func performExtract(pageIndices: [Int]) {
        guard !pageIndices.isEmpty else { return }
        guard let output = runSavePanel(defaultName: "Extracted.pdf") else { return }
        let extracted = PageOperations.extract(document.pdfDocument, pages: pageIndices.sorted())
        guard extracted.pageCount > 0, extracted.write(to: output) else {
            errorMessage = "Could not extract the selected pages."
            return
        }
        revealInFinder(output)
    }

    // MARK: - Insert

    /// Insert a blank page of `size` at `index`.
    func insertBlank(size: CGSize, at index: Int) {
        guard let page = PageOperations.makeBlankPage(size: size) else {
            errorMessage = "Could not create a blank page."
            return
        }
        document.insertPages([page], at: index, undoManager: undoManager, actionName: "Insert Blank Page")
        coordinator?.perform(.reload)
    }

    /// Insert every page of the PDFs at `urls` at `index`.
    func insertPages(fromPDFs urls: [URL], at index: Int) {
        var pages: [PDFPage] = []
        for url in urls {
            guard let doc = PDFDocument(url: url) else { continue }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { pages.append(page) }
            }
        }
        guard !pages.isEmpty else { errorMessage = "No pages found in the selected files."; return }
        document.insertPages(pages, at: index, undoManager: undoManager, actionName: "Insert Pages")
        coordinator?.perform(.reload)
    }

    /// Insert one page per image file at `index`. Decoding runs in the
    /// background (large batches can exceed ~1s); the insert lands on the main
    /// actor.
    func insertPages(fromImages urls: [URL], at index: Int) {
        runInBackground(title: "Importing images…", work: { token, report in
            try PageOperations.makePages(fromImageURLs: urls,
                                         isCancelled: { token.isCancelled },
                                         onProgress: report)
        }, completion: { [weak self] pages in
            guard let self, !pages.isEmpty else { return }
            self.document.insertPages(pages, at: index, undoManager: self.undoManager, actionName: "Insert Images")
            self.coordinator?.perform(.reload)
        })
    }

    // MARK: - Thumbnail-grid ops (fast, in-place, on the main actor)

    func rotate(_ indices: IndexSet, clockwise: Bool) {
        document.rotatePages(at: indices, by: clockwise ? 90 : -90, undoManager: undoManager)
        coordinator?.perform(.reload)
    }

    func delete(_ indices: IndexSet) {
        document.deletePages(at: indices, undoManager: undoManager)
        coordinator?.perform(.reload)
    }

    func duplicate(_ indices: IndexSet) {
        document.duplicatePages(at: indices, undoManager: undoManager)
        coordinator?.perform(.reload)
    }

    func move(_ indices: IndexSet, to destination: Int) {
        document.movePages(from: indices, to: destination, undoManager: undoManager)
        coordinator?.perform(.reload)
    }

    // MARK: - Palette registration

    /// Register (or re-register) the page ops into the ⌘K palette so the key
    /// window's controller owns them. Ids are stable, so re-registering on
    /// activation just replaces — no duplicates.
    func registerPaletteCommands() {
        let commands: [PaletteCommand] = [
            PaletteCommand(id: "page.manage", title: "Manage Pages…", category: "Pages",
                           keyboardShortcut: "⇧⌘M") { [weak self] in self?.showManagePages() },
            PaletteCommand(id: "page.merge", title: "Merge PDFs…", category: "Pages") { [weak self] in self?.showMerge() },
            PaletteCommand(id: "page.split", title: "Split PDF…", category: "Pages") { [weak self] in self?.showSplit() },
            PaletteCommand(id: "page.insert", title: "Insert Pages…", category: "Pages") { [weak self] in self?.showInsert() },
            PaletteCommand(id: "page.rotateCW", title: "Rotate All Pages Clockwise", category: "Pages") { [weak self] in
                guard let self else { return }
                self.rotate(IndexSet(0..<self.document.pdfDocument.pageCount), clockwise: true)
            },
            PaletteCommand(id: "page.rotateCCW", title: "Rotate All Pages Counterclockwise", category: "Pages") { [weak self] in
                guard let self else { return }
                self.rotate(IndexSet(0..<self.document.pdfDocument.pageCount), clockwise: false)
            }
        ]
        CommandPaletteService.shared.register(commands)
    }

    /// Remove this window's page-op commands from the ⌘K palette (on close).
    func unregisterPaletteCommands() {
        ["page.manage", "page.merge", "page.split", "page.insert", "page.rotateCW", "page.rotateCCW"]
            .forEach(CommandPaletteService.shared.unregister(id:))
    }

    // MARK: - Panels & Finder

    private func runSavePanel(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func runDirectoryPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Choose a folder for the split files."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Present an open panel for the given content types; returns chosen URLs.
    func chooseFiles(types: [UTType], allowsMultiple: Bool = true, message: String? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
