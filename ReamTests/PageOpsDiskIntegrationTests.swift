import XCTest
import PDFKit
import AppKit
@testable import Ream

/// End-to-end integration tests that exercise the *same core pipeline* the UI
/// drives — parse → operate → write real files to disk → reload and verify —
/// minus the interactive file panels (which are OS-modal and can't be scripted
/// headlessly). This is the on-disk proof behind the golden path: merge and
/// split produce correct PDF files, not just correct in-memory documents.
final class PageOpsDiskIntegrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ream-pageops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeDocument(prefix: String, pages count: Int) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for page in 1...count {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(string: "\(prefix)-\(page)",
                                                attributes: [.font: NSFont.systemFont(ofSize: 24)])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func label(_ url: URL, _ index: Int) throws -> String {
        let doc = try XCTUnwrap(PDFDocument(url: url), "could not open \(url.lastPathComponent)")
        return doc.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Merge two 3-page docs and write the result — the file on disk must have
    /// 6 pages with page 4 == source B page 1 (the brief's headline assertion,
    /// proven against a real file).
    func testMergeWritesSixPageFileToDisk() throws {
        let a = try makeDocument(prefix: "A", pages: 3)
        let b = try makeDocument(prefix: "B", pages: 3)
        let merged = try PageOperations.merge([a, b])

        let output = tempDir.appendingPathComponent("Merged.pdf")
        XCTAssertTrue(merged.write(to: output), "merge output must write to disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let reloaded = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reloaded.pageCount, 6)
        XCTAssertEqual(try label(output, 3), "B-1", "page 4 on disk must be source B page 1")
    }

    /// Split a 10-page doc by ranges and write each part — the correct number of
    /// files must exist on disk with the correct page counts and content.
    func testSplitByRangesWritesFilesToDisk() throws {
        let doc = try makeDocument(prefix: "P", pages: 10)
        let parts = try PageOperations.split(doc, ranges: "1-3, 7, 10-")

        var written: [URL] = []
        for (i, part) in parts.enumerated() {
            let url = tempDir.appendingPathComponent("Split-\(i + 1).pdf")
            XCTAssertTrue(part.write(to: url))
            written.append(url)
        }

        XCTAssertEqual(written.count, 3, "three range segments → three files")
        // Verify each file's page count and first-page identity from disk.
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: written[0])).pageCount, 3)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: written[1])).pageCount, 1)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: written[2])).pageCount, 1)
        XCTAssertEqual(try label(written[0], 0), "P-1")
        XCTAssertEqual(try label(written[1], 0), "P-7")
        XCTAssertEqual(try label(written[2], 0), "P-10")
    }

    /// Split every N pages and write parts — file count and boundaries verified
    /// from disk.
    func testSplitEveryNWritesFilesToDisk() throws {
        let doc = try makeDocument(prefix: "P", pages: 10)
        let parts = try PageOperations.split(doc, everyN: 4)

        var urls: [URL] = []
        for (i, part) in parts.enumerated() {
            let url = tempDir.appendingPathComponent("Chunk-\(i + 1).pdf")
            XCTAssertTrue(part.write(to: url))
            urls.append(url)
        }
        XCTAssertEqual(urls.map { (try? XCTUnwrap(PDFDocument(url: $0)))?.pageCount }, [4, 4, 2])
        XCTAssertEqual(try label(urls[2], 1), "P-10")
    }

    /// Extract a subset of pages to a new file on disk.
    func testExtractWritesFileToDisk() throws {
        let doc = try makeDocument(prefix: "P", pages: 5)
        let extracted = PageOperations.extract(doc, pages: [0, 2, 4])
        let output = tempDir.appendingPathComponent("Extracted.pdf")
        XCTAssertTrue(extracted.write(to: output))

        let reloaded = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reloaded.pageCount, 3)
        XCTAssertEqual((0..<3).map { reloaded.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) },
                       ["P-1", "P-3", "P-5"])
    }
}
