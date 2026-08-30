import Foundation
import CoreGraphics
import ImageIO

/// Assembles a PDF from a sequence of page images using `CGPDFContext`.
///
/// Two subtleties this centralizes:
///
/// 1. **Per-page media box.** `CGPDFContext` only honors a per-page box when it
///    is supplied as `CFData` wrapping a `CGRect` (an `NSValue` is silently
///    ignored). We wrap it correctly here.
/// 2. **JPEG pass-through.** When a page's pixels are already JPEG-compressed,
///    drawing a *JPEG-backed* `CGImage` (one created from the encoded data via
///    `CGImageSource`) makes `CGPDFContext` embed the existing DCTDecode stream
///    almost verbatim — so the output PDF is ~the sum of the JPEG sizes rather
///    than a re-compressed (or lossless, huge) copy. This is what makes the
///    target-size search's size estimate track the encoded bytes.
public enum PDFBuilder {

    /// A single page to place in the output PDF.
    public struct Page {
        /// The image to draw, already a `CGImage` (JPEG-backed when the caller
        /// wants pass-through embedding — see the type note).
        public let image: CGImage
        /// The page's media box in PDF points. The image is drawn to fill it.
        public let boxPoints: CGRect

        public init(image: CGImage, boxPoints: CGRect) {
            self.image = image
            self.boxPoints = boxPoints
        }
    }

    /// Build an in-memory PDF from the given pages.
    public static func makePDF(pages: [Page],
                               metadata: [CFString: Any]? = nil) throws -> Data {
        guard !pages.isEmpty else { throw ConversionError.emptyDocument }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw ConversionError.cannotCreateOutput("in-memory PDF")
        }

        // A default media box is required to create the context; each page then
        // overrides it via its own box dictionary.
        var defaultBox = pages[0].boxPoints
        guard let ctx = CGContext(consumer: consumer,
                                  mediaBox: &defaultBox,
                                  metadata as CFDictionary?) else {
            throw ConversionError.cannotCreateOutput("in-memory PDF")
        }

        for page in pages {
            let boxDict: [CFString: Any] = [kCGPDFContextMediaBox: boxData(page.boxPoints)]
            ctx.beginPDFPage(boxDict as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(page.image, in: page.boxPoints)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return output as Data
    }

    /// Create a `CGImage` from encoded image data. The returned image is backed
    /// by the encoded (e.g. JPEG) representation, enabling pass-through embedding.
    public static func image(fromEncoded data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Wrap a `CGRect` as the `CFData` `CGPDFContext` expects for a media box.
    private static func boxData(_ rect: CGRect) -> CFData {
        var value = rect
        return withUnsafeBytes(of: &value) { Data($0) } as CFData
    }
}
