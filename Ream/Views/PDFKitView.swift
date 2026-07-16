import SwiftUI
import PDFKit

/// SwiftUI wrapper around AppKit's `PDFView`.
///
/// PDFKit's `PDFView` is the fastest, most correct way to render PDFs on macOS
/// (Metal-backed, tiled, handles selection/search). We wrap it with
/// `NSViewRepresentable` and hand a reference back to the ``PDFViewCoordinator``
/// so menu commands can drive zoom/fit.
struct PDFKitView: NSViewRepresentable {
    let document: PDFKit.PDFDocument
    let coordinator: PDFViewCoordinator

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document

        // Continuous vertical scroll is the default reading mode (per brief).
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical

        // Auto-scale to fit on first open; user zoom overrides this.
        view.autoScales = true

        // Sensible zoom bounds.
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8.0

        // Use the system background so dark mode chrome looks native. (Content-
        // aware inversion for dark mode is a Phase 2 viewer feature.)
        view.backgroundColor = .windowBackgroundColor

        coordinator.pdfView = view
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
        // Keep the coordinator pointed at the live view across updates.
        coordinator.pdfView = nsView
    }
}
