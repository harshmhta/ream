import SwiftUI
import PDFKit

/// A tiny, generation-aware thumbnail cache for the Manage Pages grid.
///
/// PDFKit's `PDFPage.thumbnail(of:for:)` is cheap but not free; caching keeps
/// scrolling a large grid smooth. The cache is keyed by the page object plus the
/// document's mutation generation, so any structural edit (which bumps the
/// generation) transparently invalidates stale images without us tracking which
/// specific pages moved.
@MainActor
final class PageThumbnailCache: ObservableObject {
    private var images: [Key: NSImage] = [:]

    private struct Key: Hashable {
        let page: ObjectIdentifier
        let generation: Int
        let rotation: Int
        let size: Int
    }

    func thumbnail(for page: PDFPage, generation: Int, maxDimension: CGFloat) -> NSImage {
        let key = Key(page: ObjectIdentifier(page),
                      generation: generation,
                      rotation: page.rotation,
                      size: Int(maxDimension))
        if let cached = images[key] { return cached }

        let bounds = page.bounds(for: .mediaBox)
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : 0.77
        let box: CGSize = aspect >= 1
            ? CGSize(width: maxDimension, height: maxDimension / aspect)
            : CGSize(width: maxDimension * aspect, height: maxDimension)
        let image = page.thumbnail(of: box, for: .mediaBox)
        images[key] = image
        return image
    }

    /// Drop everything (called when the managed document changes identity).
    func clear() { images.removeAll() }
}
