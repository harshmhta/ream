import SwiftUI
import PDFKit
import Combine

/// Per-document annotation state and the command surface the UI drives.
///
/// Owns the active tool, current style (color/width/opacity/font), the palette
/// selection, and an undo stack. It is the single place that adds/removes
/// annotations on the document's pages, so undo, the inspector list, and the
/// save-dirty signal all stay consistent. One instance per open window, created
/// by ``PDFDocumentView``.
@MainActor
final class AnnotationController: ObservableObject {

    // MARK: Published UI state

    /// The active tool. Selecting a markup tool also remembers it as the
    /// "last-used markup tool" for the ⌃1–⌃5 palette shortcuts.
    @Published var tool: AnnotationTool = .select {
        didSet { if tool.isTextMarkup { lastMarkupTool = tool } }
    }

    /// The most recent text-markup tool, applied by the color-swatch shortcuts.
    @Published private(set) var lastMarkupTool: AnnotationTool = .highlight

    /// Currently selected palette swatch id (1–5).
    @Published var paletteSelection: Int = 1

    /// Style knobs surfaced in the toolbar for shapes/ink/free-text.
    @Published var style = AnnotationFactory.Style()

    /// Revision counter bumped whenever annotations change, so SwiftUI views
    /// (e.g. the inspector list) refresh.
    @Published private(set) var revision: Int = 0

    /// The currently selected annotation (for the inspector + delete).
    @Published var selectedAnnotation: PDFAnnotation?

    /// Set when a sticky note / free-text should open its inline editor.
    @Published var editingAnnotation: PDFAnnotation?

    // MARK: Dependencies

    let document: PDFReferenceDocument
    weak var pdfView: PDFView?

    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []

    private var cancellables: Set<AnyCancellable> = []

    init(document: PDFReferenceDocument) {
        self.document = document
        // Adopt the document's stored current palette color as the style color.
        self.style.color = AnnotationPalette.swatches[0].nsColor

        // Strip All Metadata, Remove Password and Flatten Annotations replace
        // `pdfDocument` wholesale. Everything held here — the selection, the
        // inline editor target, the undo/redo stacks — refers to annotations and
        // pages of the document that just went away, so undoing after one of
        // those would try to re-add an annotation to a detached page. Drop it,
        // exactly as ``flatten(onlySelected:)`` already does for its own swap.
        document.$pdfDocument
            .dropFirst()
            .sink { [weak self] _ in self?.documentWasReplaced() }
            .store(in: &cancellables)
    }

    /// Reset the per-document annotation state after a wholesale replacement.
    private func documentWasReplaced() {
        selectedAnnotation = nil
        editingAnnotation = nil
        undoStack.removeAll()
        redoStack.removeAll()
        revision &+= 1
    }

    // MARK: Undo model

    private enum UndoStep {
        case add(PDFAnnotation, PDFPage)
        case remove(PDFAnnotation, PDFPage)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Mutation primitives

    /// Add an annotation to a page, recording undo and marking the doc dirty.
    func add(_ annotation: PDFAnnotation, to page: PDFPage, registerUndo: Bool = true) {
        page.addAnnotation(annotation)
        if registerUndo {
            undoStack.append(.add(annotation, page))
            redoStack.removeAll()
        }
        didChange()
    }

    /// Remove an annotation, recording undo. A `Text` note carries a paired
    /// PDFKit `Popup`; drop it too so the saved file has no dangling companion.
    func remove(_ annotation: PDFAnnotation, registerUndo: Bool = true) {
        guard let page = annotation.page else { return }
        if let popup = annotation.popup, popup.page === page {
            page.removeAnnotation(popup)
        }
        page.removeAnnotation(annotation)
        if registerUndo {
            undoStack.append(.remove(annotation, page))
            redoStack.removeAll()
        }
        if selectedAnnotation === annotation { selectedAnnotation = nil }
        didChange()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        switch step {
        case .add(let annotation, let page):
            page.removeAnnotation(annotation)
            redoStack.append(.add(annotation, page))
        case .remove(let annotation, let page):
            page.addAnnotation(annotation)
            redoStack.append(.remove(annotation, page))
        }
        didChange()
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        switch step {
        case .add(let annotation, let page):
            page.addAnnotation(annotation)
            undoStack.append(.add(annotation, page))
        case .remove(let annotation, let page):
            page.removeAnnotation(annotation)
            undoStack.append(.remove(annotation, page))
        }
        didChange()
    }

    /// Called after any external mutation (e.g. inline note edit) to refresh
    /// views and flag the document for save.
    func didChange() {
        revision &+= 1
        document.annotationsDidChange()
    }

    // MARK: Tool actions invoked by the interaction view / menus

    /// Apply the current (or given) markup tool to the view's text selection.
    @discardableResult
    func applyMarkupToSelection(_ tool: AnnotationTool, color: NSColor) -> Bool {
        guard let pdfView, let selection = pdfView.currentSelection, selection.string?.isEmpty == false else {
            return false
        }
        let built = AnnotationFactory.markup(for: selection, tool: tool, color: color)
        guard !built.isEmpty else { return false }
        for (page, annotation) in built { add(annotation, to: page) }
        pdfView.clearSelection()
        return true
    }

    /// Apply a palette swatch (1–5) with the last-used markup tool.
    func applyPaletteColor(id: Int) {
        guard let swatch = AnnotationPalette.swatch(id: id) else { return }
        paletteSelection = id
        style.color = swatch.nsColor
        let markupTool = lastMarkupTool.isTextMarkup ? lastMarkupTool : .highlight
        _ = applyMarkupToSelection(markupTool, color: swatch.nsColor)
    }

    /// Build a rectangle/ellipse using the current style.
    func boxShapeAnnotation(_ tool: AnnotationTool, rect: CGRect) -> PDFAnnotation {
        AnnotationFactory.boxShape(tool, rect: rect, style: style)
    }

    /// Delete the current selection (inspector or on-canvas).
    func deleteSelected() {
        if let annotation = selectedAnnotation { remove(annotation) }
    }

    // MARK: Inspector helpers

    /// All listable annotations across pages, paired with their page index.
    func allAnnotations() -> [(page: Int, annotation: PDFAnnotation)] {
        var result: [(Int, PDFAnnotation)] = []
        let pdf = document.pdfDocument
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.isReamListable {
                result.append((pageIndex, annotation))
            }
        }
        return result
    }

    /// Scroll to and select an annotation from the inspector list.
    func reveal(_ annotation: PDFAnnotation) {
        guard let pdfView, let page = annotation.page else { return }
        pdfView.go(to: annotation.bounds, on: page)
        selectedAnnotation = annotation
    }

    // MARK: XFDF + flatten (wired to menus/palette)

    func exportXFDF(to url: URL) throws {
        let data = XFDFService.export(document.pdfDocument)
        try data.write(to: url)
    }

    func importXFDF(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let added = try XFDFService.import(data, into: document.pdfDocument)
        if added > 0 { didChange() }
    }

    /// Flatten all (or selected) annotations into page content, swapping the
    /// document's `pdfDocument` for the flattened result.
    func flatten(onlySelected: Bool) {
        let selected: [PDFAnnotation]? = onlySelected
            ? selectedAnnotation.map { [$0] }
            : nil
        guard let flattened = FlattenService.flatten(document.pdfDocument, only: selected) else { return }
        document.pdfDocument = flattened
        pdfView?.document = flattened
        selectedAnnotation = nil
        undoStack.removeAll(); redoStack.removeAll()   // flatten is not undoable
        didChange()
    }
}
