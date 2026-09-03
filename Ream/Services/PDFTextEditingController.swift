import AppKit
import Combine
import PDFKit
import ReamCore

/// Per-window bridge between ReamCore's immutable byte editor and PDFKit's
/// interaction surface. It owns the active tool, hit testing, inline field and
/// byte-snapshot undo path; parsing and writing remain UI-free in ReamCore.
@MainActor
final class PDFTextEditingController: NSObject, ObservableObject, NSTextFieldDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var highlightedRun: PDFTextRun?

    private let document: PDFReferenceDocument
    weak var coordinator: PDFViewCoordinator?
    weak var undoManager: UndoManager?
    var reportError: ((Error) -> Void)?

    private var editor: PDFTextEditor?
    private var inlineField: NSTextField?
    private var editingRun: PDFTextRun?
    private var cancellable: AnyCancellable?

    init(document: PDFReferenceDocument) {
        self.document = document
        super.init()
        cancellable = document.$pdfDocument.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            let readingState = self.coordinator?.captureReadingState()
            DispatchQueue.main.async { self.reloadEngineIfActive(preserving: readingState) }
        }
    }

    func toggle() { isActive ? deactivate() : activate() }

    func activate() {
        do {
            let parsed = try PDFTextEditor.open(data: document.dataForTextEditing())
            let page = coordinator?.currentPageIndex ?? 0
            if parsed.pageCount > 0, try parsed.textRuns(onPage: page).isEmpty {
                throw PDFTextEditingError.noTextOnPage(page)
            }
            editor = parsed
            isActive = true
            coordinator?.pdfView.textEditingController = self
            coordinator?.pdfView.window?.acceptsMouseMovedEvents = true
            coordinator?.pdfView.setNeedsDisplay(coordinator?.pdfView.bounds ?? .zero)
        } catch { fail(error) }
    }

    func deactivate() {
        cancelInlineEdit()
        highlightedRun = nil
        isActive = false
        editor = nil
        coordinator?.pdfView.textEditingController = nil
        coordinator?.pdfView.setNeedsDisplay(coordinator?.pdfView.bounds ?? .zero)
    }

    func run(at point: CGPoint, on page: PDFPage) -> PDFTextRun? {
        guard isActive, let editor, let pdfDocument = page.document else { return nil }
        let pageIndex = pdfDocument.index(for: page)
        guard pageIndex >= 0, pageIndex < pdfDocument.pageCount,
              let runs = try? editor.textRuns(onPage: pageIndex) else { return nil }
        return runs.filter { $0.userSpaceBounds.cgRect.insetBy(dx: -2, dy: -2).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    func updateHighlight(_ run: PDFTextRun?) {
        guard highlightedRun?.id != run?.id else { return }
        highlightedRun = run
        coordinator?.pdfView.setNeedsDisplay(coordinator?.pdfView.bounds ?? .zero)
    }

    func beginInlineEdit(_ run: PDFTextRun, page: PDFPage, in view: ReamPDFView) {
        cancelInlineEdit()
        editingRun = run
        highlightedRun = run
        var frame = view.convert(run.userSpaceBounds.cgRect, from: page).standardized
        frame = frame.insetBy(dx: -3, dy: -2)
        frame.size.width = max(frame.width, 72)
        frame.size.height = max(frame.height, 24)
        let field = NSTextField(frame: frame)
        field.stringValue = run.text
        field.font = .systemFont(ofSize: max(10, CGFloat(run.fontSize) * view.scaleFactor))
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = self
        view.addSubview(field)
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.utf16.count)
        inlineField = field
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineEdit(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineEdit(); return true
        }
        return false
    }

    func cancelInlineEdit() {
        inlineField?.removeFromSuperview()
        inlineField = nil
        editingRun = nil
        coordinator?.pdfView.window?.makeFirstResponder(coordinator?.pdfView)
    }

    private func commitInlineEdit() {
        guard let editor, let run = editingRun, let field = inlineField else { return }
        let replacement = field.stringValue
        do {
            let readingState = coordinator?.captureReadingState()
            let bytes = try editor.replaceText(of: run, with: replacement)
            try document.applyTextEditData(bytes, undoManager: undoManager)
            self.editor = try PDFTextEditor.open(data: bytes)
            inlineField?.removeFromSuperview()
            inlineField = nil
            editingRun = nil
            highlightedRun = nil
            coordinator?.install(document.pdfDocument, preserving: readingState)
        } catch { fail(error) }
    }

    private func reloadEngineIfActive(preserving readingState: DocumentReadingState?) {
        guard isActive else { return }
        do {
            editor = try PDFTextEditor.open(data: document.dataForTextEditing())
            highlightedRun = nil
            cancelInlineEdit()
            coordinator?.install(document.pdfDocument, preserving: readingState)
        } catch {
            deactivate()
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        cancelInlineEdit()
        reportError?(error)
    }
}

private extension PDFTextRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Idempotent ⌘K registration for the focused window's Edit Text controller.
@MainActor
enum PDFTextEditingCommands {
    private static weak var active: PDFTextEditingController?

    static func setActive(_ controller: PDFTextEditingController) {
        active = controller
        CommandPaletteService.shared.register(
            PaletteCommand(id: "edit.text", title: "Edit Text", category: "Edit",
                           keyboardShortcut: "⌃⌘E") { active?.toggle() }
        )
    }
}
