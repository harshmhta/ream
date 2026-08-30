import SwiftUI
import PDFKit

/// SwiftUI wrapper that hosts the coordinator's ``ReamPDFView``.
///
/// PDFKit's `PDFView` is the fastest, most correct way to render PDFs on macOS
/// (Metal-backed, tiled, handles selection/search). The `PDFView` instance is
/// **owned by the ``PDFViewCoordinator``** (so the thumbnail sidebar can share
/// the same instance); this representable configures it, connects the document,
/// wires the ``AnnotationController`` for authoring, and restores the saved
/// reading position on first appearance.
struct PDFKitView: NSViewRepresentable {
    let document: PDFKit.PDFDocument
    let coordinator: PDFViewCoordinator
    /// Annotation authoring controller. Optional so the viewer works without it.
    var annotationController: AnnotationController? = nil
    /// Reading state to restore when the view first shows this document.
    let initialState: DocumentReadingState?
    /// Called (debounced) whenever the reading position changes, so the owner
    /// can persist it.
    var onReadingStateChange: (() -> Void)?

    func makeCoordinator() -> Bridge {
        Bridge(parent: self)
    }

    func makeNSView(context: Context) -> ReamPDFView {
        let view = coordinator.pdfView
        view.document = document

        // Continuous vertical scroll is the default reading mode (per brief).
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8.0
        view.backgroundColor = .windowBackgroundColor

        // Wire annotation authoring (routes through the controller for
        // undo/inspector/save consistency).
        view.annotationController = annotationController
        annotationController?.pdfView = view

        // Apply the saved layout mode, then restore the reading position once the
        // view has a chance to lay out (a run-loop hop avoids a zero-size frame).
        coordinator.syncViewMode()
        if let initialState {
            DispatchQueue.main.async {
                coordinator.applyReadingState(initialState)
            }
        }

        // Observe scroll/scale changes to persist the reading position.
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ nsView: ReamPDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            coordinator.syncViewMode()
        }
        // Keep the coordinator + annotation controller pointed at the live view.
        nsView.annotationController = annotationController
        annotationController?.pdfView = nsView
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: ReamPDFView, coordinator: Bridge) {
        coordinator.stop()
    }

    /// Bridges AppKit notifications (page changed, scaled, scrolled) back to
    /// SwiftUI so we can persist the reading position without polling.
    final class Bridge: NSObject {
        var parent: PDFKitView
        private weak var view: PDFView?

        init(parent: PDFKitView) {
            self.parent = parent
        }

        func observe(_ view: PDFView) {
            self.view = view
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(readingStateChanged),
                               name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(readingStateChanged),
                               name: .PDFViewScaleChanged, object: view)
            // Scroll position within a page: observe the enclosing scroll view.
            if let scrollView = view.enclosingScrollView ?? view.documentView?.enclosingScrollView {
                scrollView.contentView.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(readingStateChanged),
                                   name: NSView.boundsDidChangeNotification,
                                   object: scrollView.contentView)
            }
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func readingStateChanged() {
            parent.onReadingStateChange?()
        }
    }
}
