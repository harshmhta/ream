import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ReamCore

/// Tests for the conversion engines. These are the load-bearing behavioral tests
/// the brief calls out: images → PDF page count, and compress target-size within
/// 5%. They run headlessly in the `ReamCore` package (also exercised by the app's
/// `ReamTests`), needing no window or signing identity.
final class ConversionTests: XCTestCase {

    // MARK: Fixtures

    /// A photo-like bitmap with high-frequency detail so JPEG quality genuinely
    /// changes the encoded size (flat fills compress identically at any quality).
    ///
    /// `seed` varies the pattern per page so a multi-page fixture has *distinct*
    /// pages. This matters: `CGPDFContext` deduplicates identical image XObjects,
    /// so identical pages would make a document's real size far smaller than the
    /// sum of its page images — unrepresentative of a real scan and misleading
    /// for the target-size search's byte accounting.
    private func noisyBitmap(width: Int, height: Int, seed: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let r = CGFloat((x * 7 + y * 13 + seed * 101) % 256) / 255.0
                let g = CGFloat((x * 3 + y * 29 + seed * 57) % 256) / 255.0
                let b = CGFloat((x * 17 + y * 5 + seed * 23) % 256) / 255.0
                ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        return ctx.makeImage()!
    }

    private func pngData(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func writeTempImage(_ image: CGImage, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ream-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try pngData(image).write(to: url)
        return url
    }

    /// A multi-page, image-heavy PDF suitable for compression tests. Each page
    /// has distinct content (see `noisyBitmap`'s `seed`) so it models a real
    /// scanned document rather than N copies of one image.
    private func imageHeavyPDF(pageCount: Int, pixels: Int = 1200) throws -> Data {
        var pages: [PDFBuilder.Page] = []
        for index in 0..<pageCount {
            let bmp = noisyBitmap(width: pixels, height: Int(Double(pixels) * 1.3), seed: index + 1)
            // Embed as a high-quality JPEG-backed image → a genuinely large PDF.
            let jpeg = try ImageEncoder.encodedData(image: bmp, format: .jpeg, quality: 0.98)
            let embeddable = PDFBuilder.image(fromEncoded: jpeg)!
            let box = CGRect(x: 0, y: 0, width: 612, height: 792)
            pages.append(PDFBuilder.Page(image: embeddable, boxPoints: box))
        }
        return try PDFBuilder.makePDF(pages: pages)
    }

    // MARK: Images → PDF

    func testImagesToPDFProducesOnePagePerImage() throws {
        let urls = try (0..<4).map { i in
            try writeTempImage(noisyBitmap(width: 300, height: 400), name: "img\(i).png")
        }
        let data = try ImagesToPDFConverter.makePDF(imageURLs: urls, pageSize: .fitImage)
        let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        XCTAssertEqual(doc.numberOfPages, 4, "one page per input image")
    }

    func testImagesToPDFFitImageUsesImageDimensions() throws {
        let url = try writeTempImage(noisyBitmap(width: 800, height: 600), name: "wide.png")
        let data = try ImagesToPDFConverter.makePDF(imageURLs: [url], pageSize: .fitImage)
        let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let box = doc.page(at: 1)!.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 800, accuracy: 1)
        XCTAssertEqual(box.height, 600, accuracy: 1)
    }

    func testImagesToPDFLetterUsesLandscapeForWideImage() throws {
        let url = try writeTempImage(noisyBitmap(width: 1000, height: 500), name: "wide.png")
        let data = try ImagesToPDFConverter.makePDF(imageURLs: [url], pageSize: .usLetter)
        let doc = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let box = doc.page(at: 1)!.getBoxRect(.mediaBox)
        XCTAssertGreaterThan(box.width, box.height, "wide image → landscape Letter page")
        XCTAssertEqual(box.width, 792, accuracy: 1)
        XCTAssertEqual(box.height, 612, accuracy: 1)
    }

    func testImagesToPDFBatchProducesOnePDFPerImage() throws {
        let urls = try (0..<3).map { i in
            try writeTempImage(noisyBitmap(width: 200, height: 200), name: "b\(i).png")
        }
        let items = try ImagesToPDFConverter.makeBatch(imageURLs: urls, pageSize: .a4)
        XCTAssertEqual(items.count, 3)
        for item in items {
            let doc = CGPDFDocument(CGDataProvider(data: item.data as CFData)!)!
            XCTAssertEqual(doc.numberOfPages, 1, "each batch item is a single-page PDF")
        }
    }

    func testImagesToPDFThrowsOnEmptyInput() {
        XCTAssertThrowsError(try ImagesToPDFConverter.makePDF(imageURLs: [], pageSize: .fitImage)) {
            XCTAssertEqual($0 as? ConversionError, .noImages)
        }
    }

    // MARK: Compression — the killer feature

    func testCompressTargetSizeHitsWithinFivePercent() throws {
        let pdf = try imageHeavyPDF(pageCount: 4)
        let originalBytes = pdf.count
        // Pick a target well below the original so the search must actually work.
        let targetBytes = originalBytes / 3
        let tolerance = 0.05

        let result = try CompressionEngine.compress(
            pdfData: pdf,
            mode: .targetSize(targetBytes: targetBytes, tolerance: tolerance)
        )

        XCTAssertTrue(result.reachedTarget, "target should be reachable for a 3× reduction")
        // Must not exceed the target beyond tolerance…
        XCTAssertLessThanOrEqual(Double(result.compressedBytes),
                                 Double(targetBytes) * (1 + tolerance),
                                 "compressed size must be at or under target within 5%")
        // Page count preserved (fidelity of structure).
        XCTAssertEqual(result.pageCount, 4)
        let outDoc = CGPDFDocument(CGDataProvider(data: result.data as CFData)!)!
        XCTAssertEqual(outDoc.numberOfPages, 4)
    }

    func testCompressTargetSizeUsesMostOfBudget() throws {
        // The killer-feature quality bar: don't just come in *under* target — get
        // *close* to it, so a "≤ 2 MB" request yields a sharp ~1.95 MB file, not a
        // needlessly blurry 0.3 MB one. A larger doc gives the search room to tune.
        let pdf = try imageHeavyPDF(pageCount: 6, pixels: 1500)
        let target = ByteFormat.bytes(fromMegabytes: 1.5)
        let result = try CompressionEngine.compress(
            pdfData: pdf, mode: .targetSize(targetBytes: target, tolerance: 0.05))

        XCTAssertTrue(result.reachedTarget, "1.5 MB is comfortably reachable")
        XCTAssertLessThanOrEqual(result.compressedBytes, target, "must not exceed the target")
        let ratio = Double(result.compressedBytes) / Double(target)
        // The continuous-DPI search should land in the upper part of the budget.
        XCTAssertGreaterThan(ratio, 0.8, "should use most of the byte budget (ratio=\(ratio))")
    }

    func testCompressTargetUnreachableReportsSmallest() throws {
        let pdf = try imageHeavyPDF(pageCount: 3)
        // An impossible target (1 KB) — engine should return its smallest effort
        // and flag it as not reached rather than throwing.
        let result = try CompressionEngine.compress(
            pdfData: pdf, mode: .targetSize(targetBytes: 1000, tolerance: 0.05))
        XCTAssertFalse(result.reachedTarget, "1 KB target is unreachable")
        XCTAssertGreaterThan(result.compressedBytes, 1000)
        XCTAssertEqual(result.pageCount, 3)
        // Even the "smallest" output is a valid, readable PDF with all pages.
        let doc = CGPDFDocument(CGDataProvider(data: result.data as CFData)!)!
        XCTAssertEqual(doc.numberOfPages, 3)
    }

    func testCompressReachedTargetNeverLies() throws {
        // The core contract: whenever the engine reports reachedTarget == true, the
        // ACTUAL written bytes must be within the tolerance band — never a
        // hardcoded assumption. Sweep a range of targets on a real multi-page doc.
        let pdf = try imageHeavyPDF(pageCount: 5, pixels: 1400)
        for fraction in [0.1, 0.25, 0.5, 0.8] {
            let target = Int(Double(pdf.count) * fraction)
            let result = try CompressionEngine.compress(
                pdfData: pdf, mode: .targetSize(targetBytes: target, tolerance: 0.05))
            if result.reachedTarget {
                XCTAssertLessThanOrEqual(result.compressedBytes, Int(Double(target) * 1.05),
                    "reachedTarget=true but \(result.compressedBytes) > \(target)*1.05 at fraction \(fraction)")
            } else {
                // If it couldn't reach the target, the output is the engine's best
                // effort and must genuinely exceed the tolerance band.
                XCTAssertGreaterThan(result.compressedBytes, Int(Double(target) * 1.05),
                    "reachedTarget=false but output already fit at fraction \(fraction)")
            }
        }
    }

    func testCompressPresetReducesSizeAndKeepsPages() throws {
        let pdf = try imageHeavyPDF(pageCount: 3)
        let result = try CompressionEngine.compress(pdfData: pdf, mode: .preset(.screen))
        XCTAssertLessThan(result.compressedBytes, pdf.count, "screen preset should shrink an image-heavy PDF")
        XCTAssertEqual(result.pageCount, 3)
    }

    func testCompressIsMonotonicInQuality() throws {
        // Underpins the binary search: higher quality ⇒ larger output.
        let pdf = try imageHeavyPDF(pageCount: 2)
        let low = try CompressionEngine.compress(pdfData: pdf, mode: .downsample(dpi: 150, quality: 0.2))
        let high = try CompressionEngine.compress(pdfData: pdf, mode: .downsample(dpi: 150, quality: 0.8))
        XCTAssertLessThan(low.compressedBytes, high.compressedBytes,
                          "size must increase with quality for the search to converge")
    }

    func testCompressCancellationThrows() throws {
        let pdf = try imageHeavyPDF(pageCount: 3)
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(
            try CompressionEngine.compress(pdfData: pdf,
                                           mode: .preset(.ebook),
                                           cancellation: token)
        ) {
            XCTAssertEqual($0 as? ConversionError, .cancelled)
        }
    }

    func testCompressInvalidPDFThrows() {
        let junk = Data("not a pdf".utf8)
        XCTAssertThrowsError(try CompressionEngine.compress(pdfData: junk, mode: .preset(.screen))) {
            XCTAssertEqual($0 as? ConversionError, .invalidPDF)
        }
    }

    // MARK: PDF → Images

    func testExportPerPageProducesOneImagePerPage() throws {
        let pdf = try imageHeavyPDF(pageCount: 5, pixels: 400)
        let outputs = try PDFToImagesExporter.export(pdfData: pdf, format: .png, dpi: 72)
        XCTAssertEqual(outputs.count, 5)
        // Each output decodes as a valid image.
        for out in outputs {
            XCTAssertNotNil(CGImageSourceCreateWithData(out.data as CFData, nil))
            XCTAssertTrue(out.fileName.hasSuffix(".png"))
        }
    }

    func testExportContactSheetPacksPages() throws {
        let pdf = try imageHeavyPDF(pageCount: 5, pixels: 300)
        // 2×2 grid → 5 pages need 2 sheets.
        let outputs = try PDFToImagesExporter.export(
            pdfData: pdf, format: .jpeg, dpi: 72,
            layout: .contactSheet(columns: 2, rows: 2))
        XCTAssertEqual(outputs.count, 2, "5 pages at 4 per sheet → 2 sheets")
    }

    func testExportDPIAffectsPixelDimensions() throws {
        let pdf = try imageHeavyPDF(pageCount: 1, pixels: 400)
        let low = try PDFToImagesExporter.export(pdfData: pdf, format: .png, dpi: 72)
        let high = try PDFToImagesExporter.export(pdfData: pdf, format: .png, dpi: 144)
        let lowImg = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(low[0].data as CFData, nil)!, 0, nil)!
        let highImg = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(high[0].data as CFData, nil)!, 0, nil)!
        XCTAssertEqual(highImg.width, lowImg.width * 2, accuracy: 2,
                       "doubling DPI doubles pixel width")
    }

    func testExportUnsupportedFormatThrows() throws {
        // WebP is not encodable on current macOS; the engine must say so clearly
        // rather than emit a broken file. If a future OS gains the encoder this
        // test's expectation flips — guarded on the live capability.
        let pdf = try imageHeavyPDF(pageCount: 1, pixels: 200)
        if ImageFormat.webp.isEncodable {
            XCTAssertNoThrow(try PDFToImagesExporter.export(pdfData: pdf, format: .webp, dpi: 72))
        } else {
            XCTAssertThrowsError(try PDFToImagesExporter.export(pdfData: pdf, format: .webp, dpi: 72)) {
                XCTAssertEqual($0 as? ConversionError, .unsupportedExportFormat("WebP"))
            }
        }
    }

    // MARK: EXIF orientation

    func testOrientationTransformsMatchImageIO() throws {
        // Base with distinct corners so every orientation is distinguishable.
        let base = makeCorneredImage()
        for orientation in UInt32(1)...8 {
            let (stored, tag) = storedPixels(base: base, orientation: orientation)
            let mine = ImagesToPDFConverter.applyOrientation(tag, to: stored)
            let reference = imageIOUpright(base: base, orientation: orientation)
            XCTAssertEqual(corners(of: mine), corners(of: reference),
                           "orientation \(orientation) must match ImageIO's upright decode")
        }
    }

    // MARK: ZIP

    func testZipWriterProducesArchive() throws {
        let entries = [
            ZipWriter.Entry(fileName: "a.txt", data: Data("alpha".utf8)),
            ZipWriter.Entry(fileName: "b.txt", data: Data("beta".utf8)),
        ]
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ream-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: dest) }
        try ZipWriter.write(entries: entries, to: dest, folderName: "My Pages")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    // MARK: File naming

    func testFileNamingSanitizesPathSeparators() {
        XCTAssertEqual(FileNaming.sanitized("a/b:c"), "a b c")
        XCTAssertEqual(FileNaming.sanitized("   "), "Untitled")
        XCTAssertEqual(FileNaming.sanitized("", fallback: "Doc"), "Doc")
        // A slash in a name must not survive to become a path separator.
        XCTAssertFalse(FileNaming.sanitized("../etc/passwd").contains("/"))
    }

    func testFileNamingUniquesCollisions() {
        var used = Set<String>()
        XCTAssertEqual(FileNaming.unique("scan.pdf", in: &used), "scan.pdf")
        XCTAssertEqual(FileNaming.unique("scan.pdf", in: &used), "scan (2).pdf")
        XCTAssertEqual(FileNaming.unique("scan.pdf", in: &used), "scan (3).pdf")
        // Case-insensitive collision (macOS default filesystem semantics).
        XCTAssertEqual(FileNaming.unique("SCAN.pdf", in: &used), "SCAN (4).pdf")
        // No-extension names uniquify too.
        XCTAssertEqual(FileNaming.unique("report", in: &used), "report")
        XCTAssertEqual(FileNaming.unique("report", in: &used), "report (2)")
    }

    func testByteFormatClampsExtremeMegabytes() {
        // Guards the target-size field: an absurd value must not overflow Int.
        XCTAssertEqual(ByteFormat.bytes(fromMegabytes: 2), 2_000_000)
        XCTAssertGreaterThan(ByteFormat.bytes(fromMegabytes: 1e300), 0) // clamped, no trap
        XCTAssertEqual(ByteFormat.bytes(fromMegabytes: -5), 1)          // floored to 1 byte
        XCTAssertEqual(ByteFormat.bytes(fromMegabytes: .nan), 1)        // non-finite → floor
    }

    // MARK: Orientation helpers

    private func makeCorneredImage() -> CGImage {
        let w = 40, h = 20
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1); ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 10))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 10, width: 20, height: 10))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: 20, y: 10, width: 20, height: 10))
        return ctx.makeImage()!
    }

    private func corners(of img: CGImage) -> [String] {
        let w = img.width, h = img.height, bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        func name(_ x: Int, _ y: Int) -> String {
            let row = (h - 1 - y); let o = row * bpr + x * 4
            let r = buf[o], g = buf[o + 1], b = buf[o + 2]
            if r > 200 && g < 80 && b < 80 { return "RED" }
            if g > 200 && r < 80 && b < 80 { return "GREEN" }
            if b > 200 && r < 80 && g < 80 { return "BLUE" }
            if r > 200 && g > 200 && b > 200 { return "WHITE" }
            return "?"
        }
        // [TL, TR, BL, BR]
        return [name(0, h - 1), name(w - 1, h - 1), name(0, 0), name(w - 1, 0)]
    }

    private func storedPixels(base: CGImage, orientation: UInt32) -> (CGImage, UInt32) {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, base, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let stored = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (stored, props[kCGImagePropertyOrientation] as! UInt32)
    }

    private func imageIOUpright(base: CGImage, orientation: UInt32) -> CGImage {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, base, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ] as CFDictionary)!
    }
}
