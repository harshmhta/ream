import SwiftUI
import PDFKit

/// SwiftUI wrapper around AppKit's `PDFView`.
///
/// PDFKit's `PDFView` is the fastest, most correct way to render PDFs on macOS
/// (Metal-backed, tiled, handles selection/search). We wrap the annotation-aware
/// ``ReamPDFView`` subclass with `NSViewRepresentable` and hand a reference back
/// to the ``PDFViewCoordinator`` (zoom/fit) and the ``AnnotationController``
/// (authoring). The annotation controller is optional so the viewer still works
/// without it.
struct PDFKitView: NSViewRepresentable {
    let document: PDFKit.PDFDocument
    let coordinator: PDFViewCoordinator
    var annotationController: AnnotationController? = nil

    func makeNSView(context: Context) -> PDFView {
        let view = ReamPDFView()
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

        view.annotationController = annotationController
        annotationController?.pdfView = view
        coordinator.pdfView = view
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
        // Keep the coordinator + annotation controller pointed at the live view.
        coordinator.pdfView = nsView
        if let reamView = nsView as? ReamPDFView {
            reamView.annotationController = annotationController
            annotationController?.pdfView = reamView
        }
    }
}
