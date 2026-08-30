import Foundation
import PDFKit

/// Undoable, in-place page mutations on the document model.
///
/// Every structural change (rotate / delete / duplicate / move / insert) routes
/// through a single primitive, ``restore(to:undoManager:actionName:)``, which
/// captures the document's page state, applies a target state, and registers the
/// inverse on the `UndoManager`. Because each restore re-registers its own
/// opposite, undo and redo ping-pong indefinitely — the canonical
/// `NSUndoManager` pattern — and we get full undo/redo for free for any op
/// expressible as "the pages used to look like X".
///
/// The `UndoManager` passed in is the document window's own (from
/// `DocumentGroup`, via `@Environment(\.undoManager)`), so registering here also
/// marks the document dirty for Autosave/Versions.
extension PDFReferenceDocument {

    /// An ordered capture of the document's pages and their rotations.
    ///
    /// Holds **strong references** to the `PDFPage` objects, so a page removed by
    /// a delete survives in the snapshot and can be re-inserted on undo. Rotation
    /// is captured separately because it is mutable state on the shared page
    /// object that re-inserting the same object would not otherwise revert.
    struct PageSnapshot {
        let pages: [PDFPage]
        let rotations: [Int]
    }

    /// Capture the current page order and per-page rotation.
    func currentPageSnapshot() -> PageSnapshot {
        var pages: [PDFPage] = []
        var rotations: [Int] = []
        for index in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: index) {
                pages.append(page)
                rotations.append(page.rotation)
            }
        }
        return PageSnapshot(pages: pages, rotations: rotations)
    }

    /// Rebuild the document so its pages exactly match `snapshot` (order +
    /// rotation). Removes every page first (detaching them) so re-inserting the
    /// same objects never trips PDFKit's "page already in document" guard.
    private func apply(_ snapshot: PageSnapshot) {
        while pdfDocument.pageCount > 0 {
            pdfDocument.removePage(at: pdfDocument.pageCount - 1)
        }
        for (offset, page) in snapshot.pages.enumerated() {
            page.rotation = snapshot.rotations[offset]
            pdfDocument.insert(page, at: pdfDocument.pageCount)
        }
    }

    /// Restore the document to `target`, registering the inverse so undo/redo
    /// alternate forever. The publish + view reload happen here so every op gets
    /// a refresh without repeating itself.
    private func restore(to target: PageSnapshot, undoManager: UndoManager?, actionName: String) {
        let inverse = currentPageSnapshot()
        apply(target)
        undoManager?.registerUndo(withTarget: self) { document in
            document.restore(to: inverse, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        bumpPageGeneration()
        objectWillChange.send()
        NotificationCenter.default.post(name: .reamPagesDidChange, object: self)
    }

    /// Run an in-place `mutation`, then register undo that restores the
    /// pre-mutation page state. All public page ops funnel through here.
    private func mutatePages(actionName: String, undoManager: UndoManager?, _ mutation: () -> Void) {
        let before = currentPageSnapshot()
        mutation()
        undoManager?.registerUndo(withTarget: self) { document in
            document.restore(to: before, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        bumpPageGeneration()
        objectWillChange.send()
        NotificationCenter.default.post(name: .reamPagesDidChange, object: self)
    }

    // MARK: - Public operations

    /// Rotate the pages at `indices` by `degrees` (a multiple of 90; positive =
    /// clockwise).
    func rotatePages(at indices: IndexSet, by degrees: Int, undoManager: UndoManager?) {
        guard !indices.isEmpty else { return }
        let name = indices.count > 1 ? "Rotate Pages" : "Rotate Page"
        mutatePages(actionName: name, undoManager: undoManager) {
            for index in indices where index >= 0 && index < pdfDocument.pageCount {
                if let page = pdfDocument.page(at: index) {
                    page.rotation = normalizedRotation(page.rotation + degrees)
                }
            }
        }
    }

    /// Delete the pages at `indices`. Refuses to delete the last remaining
    /// page(s) — a zero-page PDF is not a useful document.
    func deletePages(at indices: IndexSet, undoManager: UndoManager?) {
        guard !indices.isEmpty else { return }
        let valid = indices.filter { $0 >= 0 && $0 < pdfDocument.pageCount }
        guard !valid.isEmpty, valid.count < pdfDocument.pageCount else { return }
        let name = valid.count > 1 ? "Delete Pages" : "Delete Page"
        mutatePages(actionName: name, undoManager: undoManager) {
            for index in valid.sorted(by: >) {
                pdfDocument.removePage(at: index)
            }
        }
    }

    /// Duplicate the pages at `indices`, inserting each copy immediately after
    /// its original.
    func duplicatePages(at indices: IndexSet, undoManager: UndoManager?) {
        guard !indices.isEmpty else { return }
        let valid = indices.filter { $0 >= 0 && $0 < pdfDocument.pageCount }.sorted(by: >)
        guard !valid.isEmpty else { return }
        let name = valid.count > 1 ? "Duplicate Pages" : "Duplicate Page"
        mutatePages(actionName: name, undoManager: undoManager) {
            for index in valid {
                if let copy = pdfDocument.page(at: index)?.copy() as? PDFPage {
                    pdfDocument.insert(copy, at: index + 1)
                }
            }
        }
    }

    /// Move the pages at `sourceIndices` so they land starting at `destination`
    /// (an insertion index in the *original* coordinate space, as AppKit
    /// drag-drop reports it).
    func movePages(from sourceIndices: IndexSet, to destination: Int, undoManager: UndoManager?) {
        let sources = sourceIndices.filter { $0 >= 0 && $0 < pdfDocument.pageCount }.sorted()
        guard !sources.isEmpty else { return }
        let name = sources.count > 1 ? "Move Pages" : "Move Page"
        mutatePages(actionName: name, undoManager: undoManager) {
            let moving = sources.compactMap { pdfDocument.page(at: $0) }
            for index in sources.sorted(by: >) {
                pdfDocument.removePage(at: index)
            }
            // The insertion point shifts left by however many moved pages sat
            // before the drop target.
            let removedBefore = sources.filter { $0 < destination }.count
            var insertAt = min(max(destination - removedBefore, 0), pdfDocument.pageCount)
            for page in moving {
                pdfDocument.insert(page, at: min(insertAt, pdfDocument.pageCount))
                insertAt += 1
            }
        }
    }

    /// Insert `pages` (copies are taken so callers keep ownership of theirs) at
    /// `index`.
    func insertPages(_ pages: [PDFPage], at index: Int, undoManager: UndoManager?, actionName: String = "Insert Pages") {
        guard !pages.isEmpty else { return }
        let incoming = insertableCopies(of: pages)
        let clamped = min(max(index, 0), pdfDocument.pageCount)
        mutatePages(actionName: actionName, undoManager: undoManager) {
            for (offset, page) in incoming.enumerated() {
                pdfDocument.insert(page, at: min(clamped + offset, pdfDocument.pageCount))
            }
        }
    }

    /// Copy `pages` for insertion, re-vending foreign ones through Ream's
    /// document delegate so they come back as ``InvertingPDFPage`` instances.
    ///
    /// Pages that arrive from another file (or from `PDFPage(image:)`) belong to
    /// a document with no Ream delegate, so they are plain `PDFPage`s — and a
    /// plain page has no `draw` override, which silently opts it out of
    /// content-aware dark mode once it lands in this document. PDFKit only picks
    /// a page's class while *parsing*, so the only way to change it is to
    /// round-trip the pages through a document that vends the subclass. Copies of
    /// pages already in this document keep their class, so the common paths
    /// (duplicate, undo) skip the round-trip entirely.
    ///
    /// The re-parsed pages are copied **before** this returns: a `PDFPage` whose
    /// document has been deallocated copies as a *blank* page, so deferring the
    /// copy to the insert loop would silently insert empty sheets.
    ///
    /// Falls back to plain copies if the round-trip fails — an inserted page that
    /// does not invert is far better than a lost one.
    private func insertableCopies(of pages: [PDFPage]) -> [PDFPage] {
        func plainCopies() -> [PDFPage] { pages.map { ($0.copy() as? PDFPage) ?? $0 } }
        guard pages.contains(where: { !($0 is InvertingPDFPage) }) else { return plainCopies() }

        let staging = PDFKit.PDFDocument()
        for page in pages {
            guard let copy = page.copy() as? PDFPage else { return plainCopies() }
            staging.insert(copy, at: staging.pageCount)
        }
        guard let data = staging.dataRepresentation(),
              let reparsed = InvertingPDFDocument(data: data) else { return plainCopies() }
        reparsed.delegate = AnnotationDocumentDelegate.shared

        let adopted = (0..<reparsed.pageCount).compactMap { reparsed.page(at: $0)?.copy() as? PDFPage }
        return adopted.count == pages.count ? adopted : plainCopies()
    }

    /// Normalize any rotation to the {0, 90, 180, 270} PDFKit accepts.
    private func normalizedRotation(_ degrees: Int) -> Int {
        let stepped = Int((Double(degrees) / 90).rounded()) * 90
        return ((stepped % 360) + 360) % 360
    }
}

extension Notification.Name {
    /// Posted after any in-place page mutation so the on-screen `PDFView` can be
    /// told to re-layout (PDFKit does not always redraw on programmatic
    /// insert/remove).
    static let reamPagesDidChange = Notification.Name("com.ream.pagesDidChange")
}
