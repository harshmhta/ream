import Foundation
import CoreGraphics
import ImageIO

/// Target page size for Images → PDF.
public enum PageSizeOption: String, CaseIterable, Sendable, Identifiable {
    /// Each page exactly matches its image (at 72 DPI → 1px == 1pt).
    case fitImage
    case usLetter
    case a4

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fitImage: return "Fit Image"
        case .usLetter: return "US Letter"
        case .a4: return "A4"
        }
    }

    /// Fixed page size in PDF points, or `nil` for `fitImage` (per-image sizing).
    var pointSize: CGSize? {
        switch self {
        case .fitImage: return nil
        case .usLetter: return CGSize(width: 612, height: 792)   // 8.5×11in
        case .a4: return CGSize(width: 595.28, height: 841.89)   // 210×297mm
        }
    }
}

/// Converts raster images into PDFs.
///
/// UI-free (CoreGraphics + ImageIO), so it lives in `ReamCore` and is reusable by
/// the CLI. Supports HEIC/PNG/JPEG/TIFF and anything else `CGImageSource` decodes.
public enum ImagesToPDFConverter {

    /// A single output when producing one PDF per image (batch mode).
    public struct BatchItem: Sendable {
        /// Suggested file name stem (source name without extension).
        public let nameStem: String
        public let data: Data
    }

    // MARK: Single combined PDF

    /// Combine `imageURLs` into one PDF, one image per page.
    ///
    /// - Parameters:
    ///   - imageURLs: images in the desired page order.
    ///   - pageSize: `fitImage`, `usLetter`, or `a4`.
    ///   - margin: points of white margin around each image on fixed-size pages
    ///     (ignored for `fitImage`).
    public static func makePDF(imageURLs: [URL],
                               pageSize: PageSizeOption,
                               margin: CGFloat = 24,
                               progress: ProgressHandler? = nil,
                               cancellation: CancellationToken? = nil) throws -> Data {
        guard !imageURLs.isEmpty else { throw ConversionError.noImages }

        var pages: [PDFBuilder.Page] = []
        pages.reserveCapacity(imageURLs.count)

        for (index, url) in imageURLs.enumerated() {
            try cancellation?.checkCancellation()
            try autoreleasepool {
                guard let image = loadImage(url) else {
                    throw ConversionError.unreadableImage(url.lastPathComponent)
                }
                pages.append(page(for: image, pageSize: pageSize, margin: margin))
            }
            progress?(ConversionProgress(
                fraction: Double(index + 1) / Double(imageURLs.count),
                message: "Adding image \(index + 1) of \(imageURLs.count)…"
            ))
        }

        return try PDFBuilder.makePDF(pages: pages)
    }

    // MARK: Batch (one PDF per image)

    /// Produce one single-page PDF per image.
    public static func makeBatch(imageURLs: [URL],
                                 pageSize: PageSizeOption,
                                 margin: CGFloat = 24,
                                 progress: ProgressHandler? = nil,
                                 cancellation: CancellationToken? = nil) throws -> [BatchItem] {
        guard !imageURLs.isEmpty else { throw ConversionError.noImages }

        var items: [BatchItem] = []
        items.reserveCapacity(imageURLs.count)

        for (index, url) in imageURLs.enumerated() {
            try cancellation?.checkCancellation()
            try autoreleasepool {
                guard let image = loadImage(url) else {
                    throw ConversionError.unreadableImage(url.lastPathComponent)
                }
                let onePage = page(for: image, pageSize: pageSize, margin: margin)
                let data = try PDFBuilder.makePDF(pages: [onePage])
                let stem = url.deletingPathExtension().lastPathComponent
                items.append(BatchItem(nameStem: stem, data: data))
            }
            progress?(ConversionProgress(
                fraction: Double(index + 1) / Double(imageURLs.count),
                message: "Converting \(index + 1) of \(imageURLs.count)…"
            ))
        }
        return items
    }

    // MARK: Page layout

    /// Build a single page placing `image` per the chosen page size.
    private static func page(for image: CGImage,
                             pageSize: PageSizeOption,
                             margin: CGFloat) -> PDFBuilder.Page {
        let imageSize = CGSize(width: image.width, height: image.height)

        guard let fixed = pageSize.pointSize else {
            // Fit image: page == image at 72 DPI.
            return PDFBuilder.Page(image: image,
                                   boxPoints: CGRect(origin: .zero, size: imageSize))
        }

        // Choose orientation to best match the image, so a wide photo lands on a
        // landscape page rather than being shrunk into a portrait one.
        let imageIsLandscape = imageSize.width > imageSize.height
        let box = imageIsLandscape
            ? CGSize(width: max(fixed.width, fixed.height), height: min(fixed.width, fixed.height))
            : CGSize(width: min(fixed.width, fixed.height), height: max(fixed.width, fixed.height))

        let content = CGRect(x: margin, y: margin,
                             width: box.width - margin * 2,
                             height: box.height - margin * 2)
        let placed = aspectFit(imageSize: imageSize, into: content)
        // Note: `PDFBuilder` draws one image per page filling the given box. To
        // place an image within a larger page with margins, we render onto a
        // page-sized backdrop first.
        let composited = composite(image: image, on: box, in: placed)
        return PDFBuilder.Page(image: composited,
                               boxPoints: CGRect(origin: .zero, size: box))
    }

    /// Aspect-fit `imageSize` inside `bounds`, centered.
    private static func aspectFit(imageSize: CGSize, into bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: bounds.midX - width / 2,
                      y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    /// Render `image` into `frame` on a white `pageSize` canvas and return the
    /// composited bitmap (so a fixed page shows margins around the image).
    private static func composite(image: CGImage, on pageSize: CGSize, in frame: CGRect) -> CGImage {
        // Rasterize the composed page at ~150 DPI so text-bearing scans stay crisp
        // without ballooning memory.
        let scale: CGFloat = 150.0 / 72.0
        let pxW = max(1, Int((pageSize.width * scale).rounded()))
        let pxH = max(1, Int((pageSize.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(image, in: frame)
        return ctx.makeImage() ?? image
    }

    /// Decode an image file to a `CGImage`, applying any EXIF orientation so
    /// phone photos (HEIC/JPEG) aren't rotated sideways.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return applyOrientation(orientationRaw, to: image)
    }

    /// Redraw `image` so that EXIF `orientation` (1...8) becomes the identity.
    /// Orientation 1 (the common case) returns the image untouched.
    ///
    /// The `(rotation, flipX, flipY)` per orientation were derived by
    /// brute-forcing every combination against ImageIO's own transformed decode
    /// (`kCGImageSourceCreateThumbnailWithTransform`) and covered by a unit test.
    /// Rotation is measured in 90° CCW steps applied in CoreGraphics' coordinate
    /// space (origin bottom-left).
    static func applyOrientation(_ orientation: UInt32, to image: CGImage) -> CGImage {
        guard orientation >= 2, orientation <= 8 else { return image }

        // (rotationSteps of 90° CCW, flip horizontally, flip vertically)
        let recipe: (rot: Int, flipX: Bool, flipY: Bool)
        switch orientation {
        case 2: recipe = (0, true, false)
        case 3: recipe = (0, true, true)
        case 4: recipe = (0, false, true)
        case 5: recipe = (1, false, true)
        case 6: recipe = (1, true, true)
        case 7: recipe = (1, true, false)
        case 8: recipe = (1, false, false)
        default: recipe = (0, false, false)
        }

        let w = image.width, h = image.height
        // A single 90°/270° rotation swaps width and height.
        let swaps = recipe.rot % 2 != 0
        let outW = swaps ? h : w
        let outH = swaps ? w : h

        // Always compose into an RGBA context regardless of the source's color
        // space. Pairing `premultipliedLast` (a 4-channel/alpha layout) with a
        // non-RGB space like DeviceGray or CMYK makes CGContext creation fail — so
        // a sideways grayscale or CMYK scan would otherwise be left un-rotated.
        // CoreGraphics converts the drawn image into RGB for us.
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }

        // Compose about the output center: flip, then rotate, then draw the
        // source centered. This keeps the math order-independent and matches the
        // brute-forced recipe exactly.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        if recipe.flipX { ctx.scaleBy(x: -1, y: 1) }
        if recipe.flipY { ctx.scaleBy(x: 1, y: -1) }
        ctx.rotate(by: CGFloat(recipe.rot) * (.pi / 2))
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
