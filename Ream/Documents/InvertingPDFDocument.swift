import PDFKit
import CoreGraphics
import AppKit

/// A `PDFDocument` that carries the per-document dark-content flag.
///
/// The custom-page plumbing lives on ``AnnotationDocumentDelegate`` (the single
/// document delegate, which returns ``InvertingPDFPage`` from `classForPage()`)
/// rather than here, because a `PDFDocument` has only one delegate and Ream also
/// needs it for custom annotation subclasses. This subclass just holds the flag;
/// each ``PDFReferenceDocument`` owns exactly one `PDFDocument`, so per-document
/// is the right scope.
///
/// When `invertContent` is `false` (the default) pages draw through the stock
/// PDFKit path unchanged — so this is invisible to every other feature until the
/// user turns dark-content on.
final class InvertingPDFDocument: PDFKit.PDFDocument {
    /// Toggle content-aware inversion for every page in this document.
    var invertContent: Bool = false
}

/// A page that, when its document has `invertContent` on, renders itself with a
/// chroma-masked colour inversion (white paper → dark, colour photos preserved).
final class InvertingPDFPage: PDFPage {

    /// Guard against pathological allocations from extreme zoom (~40 MP cap).
    ///
    /// This is a `static` constant, not a stored instance property, on purpose:
    /// PDFKit instantiates `classForPage()` subclasses through a path that does
    /// **not** run Swift's stored-property initializers, so an instance `let`
    /// here would silently read as `0` and disable inversion entirely. Type-level
    /// storage sidesteps that. (Discovered via a pixel-level render test.)
    private static let maxPixels = 40_000_000

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard let doc = document as? InvertingPDFDocument, doc.invertContent else {
            super.draw(with: box, to: context)
            return
        }

        let bounds = self.bounds(for: box)
        guard bounds.width > 0, bounds.height > 0 else {
            super.draw(with: box, to: context)
            return
        }

        // Match the offscreen resolution to what PDFKit is about to paint on
        // screen (from the current CTM) so inverted pages stay crisp at any zoom.
        let deviceTransform = context.userSpaceToDeviceSpaceTransform
        let scaleX = max(hypot(deviceTransform.a, deviceTransform.b), 1)
        let scaleY = max(hypot(deviceTransform.c, deviceTransform.d), 1)
        let pixelW = Int((bounds.width * scaleX).rounded())
        let pixelH = Int((bounds.height * scaleY).rounded())
        guard pixelW > 0, pixelH > 0, pixelW * pixelH <= Self.maxPixels else {
            super.draw(with: box, to: context)
            return
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(
            data: nil,
            width: pixelW,
            height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            super.draw(with: box, to: context)
            return
        }

        // Paint an opaque white page first: transparent PDF regions then in, and
        // then invert to dark, giving a proper dark background rather than black
        // fringing around anti-aliased glyphs.
        bitmap.setFillColor(NSColor.white.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        // Map page space → bitmap pixels (both are y-up, so no flip needed).
        bitmap.scaleBy(x: scaleX, y: scaleY)
        bitmap.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        super.draw(with: box, to: bitmap)

        guard let rendered = bitmap.makeImage() else {
            super.draw(with: box, to: context)
            return
        }

        let source = CIImage(cgImage: rendered)
        guard let outputCG = DarkContentInverter.render(source) else {
            super.draw(with: box, to: context)
            return
        }

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(outputCG, in: bounds)
        context.restoreGState()
    }
}
