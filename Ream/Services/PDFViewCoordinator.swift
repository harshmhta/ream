import PDFKit

/// Zoom / display actions that the UI can ask a `PDFView` to perform.
///
/// This wrapper keeps PDFKit interaction in one place so menu commands, the
/// (future) toolbar, and the command palette all drive the view through the
/// same small vocabulary rather than reaching into `PDFView` directly.
enum PDFViewAction {
    case zoomIn
    case zoomOut
    case actualSize
    case fitWidth
    case fitPage
}

/// Bridges SwiftUI commands to the underlying AppKit `PDFView`.
///
/// The `NSViewRepresentable` sets `pdfView` when the view is made; menu commands
/// send actions through ``perform(_:)``. Weakly held so a closed window's view
/// can be released.
@MainActor
final class PDFViewCoordinator: ObservableObject {
    weak var pdfView: PDFView?

    /// Zoom step applied for zoom-in / zoom-out (25% per press).
    private let zoomStep: CGFloat = 1.25

    func perform(_ action: PDFViewAction) {
        guard let pdfView else { return }
        switch action {
        case .zoomIn:
            pdfView.scaleFactor = min(pdfView.scaleFactor * zoomStep, pdfView.maxScaleFactor)
        case .zoomOut:
            pdfView.scaleFactor = max(pdfView.scaleFactor / zoomStep, pdfView.minScaleFactor)
        case .actualSize:
            // "Actual size" = 100% (1 PDF point : 1 screen point).
            pdfView.autoScales = false
            pdfView.scaleFactor = 1.0
        case .fitWidth:
            // PDFKit has no direct "fit width"; approximate by sizing the scale
            // so the page's media width fills the view, then keep it sticky.
            fitWidth(in: pdfView)
        case .fitPage:
            pdfView.autoScales = true
        }
    }

    private func fitWidth(in pdfView: PDFView) {
        guard let page = pdfView.currentPage ?? pdfView.document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: pdfView.displayBox).width
        guard pageWidth > 0 else { return }
        pdfView.autoScales = false
        // Leave a small margin for the scroller / insets.
        let available = pdfView.bounds.width - 16
        pdfView.scaleFactor = max(available / pageWidth, pdfView.minScaleFactor)
    }
}
