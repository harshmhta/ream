import Foundation
import CoreGraphics

/// Renders `CGPDFPage`s to bitmaps at a chosen DPI, honoring each page's crop
/// box and `/Rotate` entry.
///
/// UI-free (CoreGraphics only) so it belongs in `ReamCore` and can back both the
/// compression engine and PDF → Images export, as well as the future CLI.
public enum PDFPageRasterizer {

    /// The point size a page occupies once its own rotation is applied — this is
    /// what the user perceives as the page's width/height.
    public static func displaySize(of page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox)
        let rotation = normalizedRotation(page.rotationAngle)
        if rotation == 90 || rotation == 270 {
            return CGSize(width: crop.height, height: crop.width)
        }
        return crop.size
    }

    /// Render a page to a `CGImage` at `dpi` dots per inch.
    ///
    /// - Parameters:
    ///   - page: the source page (1-indexed within its `CGPDFDocument`).
    ///   - dpi: output resolution; 72 DPI == the page's point size 1:1.
    ///   - grayscale: render into a device-gray context (smaller JPEGs; used by
    ///     the aggressive end of the compression search).
    /// - Returns: the rendered bitmap, or `nil` if a context couldn't be made.
    public static func render(page: CGPDFPage,
                              dpi: CGFloat,
                              grayscale: Bool = false) -> CGImage? {
        let displayed = displaySize(of: page)
        guard displayed.width > 0, displayed.height > 0 else { return nil }

        let scale = dpi / 72.0
        let pixelWidth = max(1, Int((displayed.width * scale).rounded()))
        let pixelHeight = max(1, Int((displayed.height * scale).rounded()))

        let colorSpace = grayscale
            ? CGColorSpaceCreateDeviceGray()
            : CGColorSpaceCreateDeviceRGB()
        // Opaque context: PDF pages have no alpha and JPEG can't store it. A white
        // backdrop matches how the page renders on paper / on screen.
        let bitmapInfo = grayscale
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        ctx.scaleBy(x: scale, y: scale)

        // `getDrawingTransform` maps the crop box into our target rect and applies
        // the page's `/Rotate`, so we don't have to reason about orientation.
        let target = CGRect(origin: .zero, size: displayed)
        let transform = page.getDrawingTransform(.cropBox,
                                                 rect: target,
                                                 rotate: 0,
                                                 preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)

        return ctx.makeImage()
    }

    /// Normalize an arbitrary rotation angle to one of {0, 90, 180, 270}.
    static func normalizedRotation(_ angle: Int32) -> Int32 {
        ((angle % 360) + 360) % 360
    }
}
