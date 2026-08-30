import SwiftUI
import PDFKit
import AppKit

/// Left-sidebar thumbnails, backed by AppKit's `PDFThumbnailView`.
///
/// We wrap the AppKit control rather than hand-rolling a `LazyVStack` of
/// rendered pages because `PDFThumbnailView` is already lazy and virtualized —
/// it only renders visible thumbnails and recycles them — which is exactly the
/// "virtualized, fast on 500-page docs" requirement, for free. Clicking a
/// thumbnail drives the shared `PDFView` (via its own linkage), and the current
/// page stays highlighted because both views share one `PDFView`.
struct ThumbnailSidebarView: NSViewRepresentable {
    let pdfView: PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumb = PDFThumbnailView()
        thumb.thumbnailSize = CGSize(width: 120, height: 160)
        thumb.maximumNumberOfColumns = 1
        thumb.backgroundColor = .clear
        thumb.pdfView = pdfView
        return thumb
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView {
            nsView.pdfView = pdfView
        }
    }
}
