import XCTest
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ReamCore
@testable import Ream

/// App-target coverage for the Convert & Export feature. This is the suite CI
/// runs (`-only-testing:ReamTests`), so it re-asserts the two load-bearing
/// behaviors from the brief — **images → PDF page count** and **compress
/// target-size within 5%** — through the `ReamCore` engines the app links, plus
/// a round-trip on the real bundled `sample.pdf` fixture.
///
/// Exhaustive engine edge-case coverage lives in `ReamCore`'s own test target.
final class ConversionTests: XCTestCase {

    // MARK: Fixtures

    private func bitmap(width: Int, height: Int, seed: Int) -> CGImage {
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

    private func writeTempPNG(seed: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ream-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("img-\(seed).png")
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, bitmap(width: 400, height: 300, seed: seed), nil)
        CGImageDestinationFinalize(dest)
        try (data as Data).write(to: url)
        return url
    }

    private func imageHeavyPDF(pageCount: Int) throws -> Data {
        var pages: [PDFBuilder.Page] = []
        for index in 0..<pageCount {
            let jpeg = try ImageEncoder.encodedData(image: bitmap(width: 1200, height: 1560, seed: index + 1),
                                                    format: .jpeg, quality: 0.98)
            let image = PDFBuilder.image(fromEncoded: jpeg)!
            pages.append(PDFBuilder.Page(image: image, boxPoints: CGRect(x: 0, y: 0, width: 612, height: 792)))
        }
        return try PDFBuilder.makePDF(pages: pages)
    }

    // MARK: Brief requirement — images → PDF page count

    func testImagesToPDFPageCountMatchesInputCount() throws {
        let urls = try (0..<5).map { try writeTempPNG(seed: $0) }
        let data = try ImagesToPDFConverter.makePDF(imageURLs: urls, pageSize: .fitImage)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(doc.pageCount, 5, "images → PDF must produce exactly one page per image")
    }

    // MARK: Brief requirement — compress target-size within 5%

    func testCompressTargetSizeWithinFivePercent() throws {
        let pdf = try imageHeavyPDF(pageCount: 4)
        let target = pdf.count / 3
        let result = try CompressionEngine.compress(
            pdfData: pdf, mode: .targetSize(targetBytes: target, tolerance: 0.05))

        XCTAssertTrue(result.reachedTarget)
        XCTAssertLessThanOrEqual(Double(result.compressedBytes), Double(target) * 1.05,
                                 "compressed output must be within 5% of the target")
        // Structure preserved.
        let doc = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertEqual(doc.pageCount, 4)
    }

    // MARK: Real fixture round-trip

    func testExportBundledSampleProducesOneImagePerPage() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "sample", withExtension: "pdf") else {
            throw XCTSkip("sample.pdf fixture not found in test bundle")
        }
        let data = try Data(contentsOf: url)
        let pageCount = try XCTUnwrap(PDFDocument(data: data)).pageCount

        let outputs = try PDFToImagesExporter.export(pdfData: data, format: .png, dpi: 100)
        XCTAssertEqual(outputs.count, pageCount, "one PNG per page of the real sample PDF")
        for out in outputs {
            XCTAssertNotNil(CGImageSourceCreateWithData(out.data as CFData, nil),
                            "each exported file must be a decodable image")
        }
    }

    // MARK: App wiring smoke test

    @MainActor
    func testCoordinatorReadsDocumentData() async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "sample", withExtension: "pdf") else {
            throw XCTSkip("sample.pdf fixture not found in test bundle")
        }
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try XCTUnwrap(PDFDocument(url: url))

        let coordinator = ConversionCoordinator()
        coordinator.document = doc
        XCTAssertTrue(coordinator.hasDocumentData)
        let maybeData = await coordinator.currentPDFData()
        let data = try XCTUnwrap(maybeData)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertNotNil(PDFDocument(data: data))
    }
}
