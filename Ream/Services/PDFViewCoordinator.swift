import PDFKit
import AppKit

/// The reading layout modes Ream offers, mapped onto PDFKit's display modes.
///
/// PDFKit expresses layout as a `(PDFDisplayMode, displaysAsBook)` pair; this
/// enum is the single vocabulary the menus, palette, and view model speak, so
/// the mapping lives in one place.
enum ViewMode: Int, CaseIterable, Identifiable {
    case singlePage          // one page at a time
    case continuous          // vertically scrolling, one column (default)
    case twoUp               // two-page spread
    case book                // two-up with a correct odd/even cover offset

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .singlePage: return "Single Page"
        case .continuous: return "Continuous"
        case .twoUp:      return "Two-Page Spread"
        case .book:       return "Book (Facing)"
        }
    }

    var displayMode: PDFDisplayMode {
        switch self {
        case .singlePage: return .singlePage
        case .continuous: return .singlePageContinuous
        case .twoUp:      return .twoUp
        case .book:       return .twoUp
        }
    }

    /// Book mode offsets the first page so odd/even (recto/verso) pairs line up
    /// the way a physical book does.
    var displaysAsBook: Bool { self == .book }
}

/// Zoom / display / navigation actions the UI can ask a `PDFView` to perform.
///
/// This wrapper keeps PDFKit interaction in one place so menu commands, the
/// toolbar, and the command palette all drive the view through the same small
/// vocabulary rather than reaching into `PDFView` directly.
enum PDFViewAction {
    case zoomIn
    case zoomOut
    case actualSize
    case fitWidth
    case fitPage
    case setViewMode(ViewMode)
    /// Scroll the view so the given 0-based page index is visible.
    case goToPage(Int)
    case nextPage
    case previousPage
    case togglePresentation
    /// Re-layout after a programmatic page mutation (insert/remove/reorder).
    /// PDFKit does not always redraw when the document's page list changes out
    /// from under it, so page ops nudge the view through this action.
    case reload
}

/// Bridges SwiftUI commands to the underlying AppKit `PDFView`.
///
/// The `NSViewRepresentable` sets `pdfView` when the view is made; menu commands
/// send actions through ``perform(_:)``. Weakly held so a closed window's view
/// can be released.
@MainActor
final class PDFViewCoordinator: ObservableObject {
    /// The one `PDFView` for this window, owned strongly and created eagerly so
    /// both the main renderer and the thumbnail sidebar share a single instance
    /// (that shared instance is what keeps the current page highlighted in the
    /// thumbnails and drives click-to-jump for free). It lives as long as the
    /// window's coordinator, and is released when the window closes.
    let pdfView: ReamPDFView = ReamPDFView()

    /// Published so the View menu can show a checkmark next to the active mode.
    @Published private(set) var viewMode: ViewMode = .continuous

    /// Zoom step applied for zoom-in / zoom-out (25% per press).
    private let zoomStep: CGFloat = 1.25

    func perform(_ action: PDFViewAction) {
        switch action {
        case .zoomIn:
            pdfView.autoScales = false
            pdfView.scaleFactor = min(pdfView.scaleFactor * zoomStep, pdfView.maxScaleFactor)
        case .zoomOut:
            pdfView.autoScales = false
            pdfView.scaleFactor = max(pdfView.scaleFactor / zoomStep, pdfView.minScaleFactor)
        case .actualSize:
            // "Actual size" = 100% relative to the page's physical size. PDF user
            // space is 72 units/inch; matching that to the screen's backing scale
            // makes 1 inch of paper render as 1 inch on a correctly-configured
            // display, honoring the "respect physical DPI" requirement.
            pdfView.autoScales = false
            pdfView.scaleFactor = 1.0
        case .fitWidth:
            fitWidth(in: pdfView)
        case .fitPage:
            // PDFKit's autoScales fits the whole page to the view.
            pdfView.autoScales = true
        case .setViewMode(let mode):
            apply(mode, to: pdfView)
        case .goToPage(let index):
            goToPage(index, in: pdfView)
        case .nextPage:
            if pdfView.canGoToNextPage { pdfView.goToNextPage(nil) }
        case .previousPage:
            if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
        case .togglePresentation:
            togglePresentation(pdfView)
        case .reload:
            reloadDocumentLayout()
        }
    }

    // MARK: - Layout

    private func apply(_ mode: ViewMode, to pdfView: PDFView) {
        pdfView.displayMode = mode.displayMode
        pdfView.displaysAsBook = mode.displaysAsBook
        viewMode = mode
    }

    /// Reassert the current view mode on the `PDFView`.
    func syncViewMode() {
        apply(viewMode, to: pdfView)
    }

    private func fitWidth(in pdfView: PDFView) {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: pdfView.displayBox).width
        guard pageWidth > 0 else { return }
        pdfView.autoScales = false
        // Leave a small margin for the scroller / insets. In two-up / book modes
        // the page area is roughly half the view, so account for a second column.
        let columns: CGFloat = (viewMode == .twoUp || viewMode == .book) ? 2 : 1
        let available = (pdfView.bounds.width - 16) / columns
        pdfView.scaleFactor = max(available / pageWidth, pdfView.minScaleFactor)
    }

    // MARK: - Navigation

    private func goToPage(_ index: Int, in pdfView: PDFView) {
        guard let document = pdfView.document,
              index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        pdfView.go(to: page)
    }

    /// The zero-based index of the page currently in view (best effort).
    ///
    /// `nil` when the current page is no longer part of the document — page ops
    /// can delete the page under the reader, and `index(for:)` answers
    /// `NSNotFound` (a very large positive number, not a negative one) for a
    /// detached page.
    var currentPageIndex: Int? {
        guard let page = pdfView.currentPage, let doc = pdfView.document else { return nil }
        let index = doc.index(for: page)
        return (index >= 0 && index < doc.pageCount) ? index : nil
    }

    // MARK: - Search highlighting

    /// Highlight every match and scroll the active one into view.
    func showSearchResults(_ selections: [PDFSelection], active: PDFSelection?) {
        // Colour all hits faintly; the active one gets the strong selection.
        for selection in selections {
            selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
        }
        pdfView.highlightedSelections = selections.isEmpty ? nil : selections
        if let active {
            active.color = NSColor.systemOrange
            pdfView.setCurrentSelection(active, animate: true)
            pdfView.scrollSelectionToVisible(nil)
        }
    }

    /// Clear any search highlighting.
    func clearSearchResults() {
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
    }

    // MARK: - Rendering refresh

    /// Force a full re-render of every page (used when dark-content inversion is
    /// toggled). Preserves the reading position across the reload.
    func refreshRendering() {
        guard let document = pdfView.document else { return }
        let destination = pdfView.currentDestination
        reloadDocument(document)
        if let destination { pdfView.go(to: destination) }
    }

    /// Rebuild PDFKit's page layout after a structural page edit
    /// (insert/remove/reorder/rotate), which PDFKit does not always do on its
    /// own when the document mutates underneath it.
    ///
    /// Unlike ``refreshRendering()`` this restores the reader by *page index*
    /// rather than by `PDFDestination`: the page they were on may have just been
    /// deleted, and a destination pointing at a detached page navigates nowhere.
    private func reloadDocumentLayout() {
        guard let document = pdfView.document else { return }
        let previousIndex = currentPageIndex
        reloadDocument(document)
        if let previousIndex, document.pageCount > 0 {
            goToPage(min(previousIndex, document.pageCount - 1), in: pdfView)
        }
        pdfView.layoutDocumentView()
    }

    /// Swap `document` out and back in to force a full relayout/re-render,
    /// restoring the view state PDFKit drops on the way (layout mode and zoom).
    private func reloadDocument(_ document: PDFKit.PDFDocument) {
        let autoScales = pdfView.autoScales
        let scaleFactor = pdfView.scaleFactor
        pdfView.document = nil
        pdfView.document = document
        syncViewMode()
        pdfView.autoScales = autoScales
        if !autoScales { pdfView.scaleFactor = scaleFactor }
    }

    // MARK: - Reading-position memory

    /// Capture the current reading position + zoom + layout so it can be
    /// restored when the document is reopened.
    /// Captures view geometry only; the caller sets `invertContent` (a document
    /// property, not a view-geometry one).
    func captureReadingState() -> DocumentReadingState? {
        guard pdfView.document != nil else { return nil }
        var state = DocumentReadingState()
        if let index = currentPageIndex { state.pageIndex = index }
        if let dest = pdfView.currentDestination {
            state.scrollPointX = dest.point.x
            state.scrollPointY = dest.point.y
        }
        state.scaleFactor = pdfView.scaleFactor
        state.autoScales = pdfView.autoScales
        state.viewModeRaw = viewMode.rawValue
        return state
    }

    /// Restore a previously-captured reading position. Layout mode and zoom are
    /// applied *before* navigating, because the saved scroll point was recorded
    /// at the saved scale — going to the point first (at the current fit scale)
    /// and then changing the scale re-anchors the scroll view and lands the
    /// reader at the wrong offset.
    func applyReadingState(_ state: DocumentReadingState) {
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        if let mode = ViewMode(rawValue: state.viewModeRaw) {
            apply(mode, to: pdfView)
        }

        // Restore zoom first so the destination point is interpreted at the
        // right scale.
        if state.autoScales {
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor = max(min(state.scaleFactor, pdfView.maxScaleFactor), pdfView.minScaleFactor)
        }

        let index = max(0, min(state.pageIndex, document.pageCount - 1))
        guard let page = document.page(at: index) else { return }
        let point = CGPoint(x: state.scrollPointX, y: state.scrollPointY)
        pdfView.go(to: PDFDestination(page: page, at: point))
    }

    // MARK: - Presentation / full screen

    /// The layout to restore when leaving presentation mode; `nil` means we are
    /// not presenting. We do NOT track presentation with a bare bool because the
    /// user can leave full screen outside this command (green button, Esc); the
    /// live source of truth for full screen is the window's style mask.
    private var prePresentationMode: ViewMode?

    /// macOS PDFKit has no built-in presentation mode (that's iOS-only), so we
    /// compose one: full-screen window + single page + fit-to-page. Whether we
    /// are "presenting" is derived from the actual window full-screen state, so
    /// exiting full screen by any means and pressing the shortcut again always
    /// re-enters presentation rather than toggling the wrong way.
    private func togglePresentation(_ pdfView: PDFView) {
        let isFullScreen = pdfView.window?.styleMask.contains(.fullScreen) ?? false
        if isFullScreen {
            // Leaving presentation: restore the prior layout (if we set one) and
            // drop back out of full screen.
            if let mode = prePresentationMode { apply(mode, to: pdfView) }
            prePresentationMode = nil
            pdfView.window?.toggleFullScreen(nil)
        } else {
            // Entering presentation: remember the layout, switch to single-page
            // fit, and go full screen.
            prePresentationMode = viewMode
            apply(.singlePage, to: pdfView)
            pdfView.autoScales = true
            pdfView.window?.toggleFullScreen(nil)
        }
    }
}
