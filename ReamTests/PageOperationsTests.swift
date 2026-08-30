import XCTest
import PDFKit
import AppKit
@testable import Ream

/// Tests for the UI-free ``PageOperations`` core: merge (incl. interleave),
/// range parsing, split (ranges / every-N / bookmarks), and extract.
///
/// Synthetic PDFs are built with one distinct, machine-readable label per page
/// ("A-1", "A-2", …) so assertions can prove *which* source page landed where —
/// not just that page counts add up.
final class PageOperationsTests: XCTestCase {

    // MARK: - Fixtures

    /// Build an in-memory PDF with `count` pages, each stamped with
    /// "`prefix`-`n`" so its origin is recoverable via `PDFPage.string`.
    private func makeDocument(prefix: String, pages count: Int) throws -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))

        for page in 1...count {
            context.beginPDFPage(nil)
            let label = "\(prefix)-\(page)"
            let attributed = NSAttributedString(
                string: label,
                attributes: [.font: NSFont.systemFont(ofSize: 24)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: 200)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data), "failed to build synthetic PDF")
    }

    /// The trimmed text content of a page, for identity assertions.
    private func label(_ document: PDFDocument, _ index: Int) -> String {
        document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Merge (the brief's headline assertion)

    func testMergeTwoThreePageDocumentsProducesSixPages() throws {
        let a = try makeDocument(prefix: "A", pages: 3)
        let b = try makeDocument(prefix: "B", pages: 3)

        let merged = try PageOperations.merge([a, b])

        XCTAssertEqual(merged.pageCount, 6, "3 + 3 pages must merge to 6")
        // Page 4 (0-based index 3) must be source B's first page.
        XCTAssertEqual(label(merged, 3), "B-1", "page 4 must equal source B page 1")
        // And the whole sequence must be A1,A2,A3,B1,B2,B3.
        XCTAssertEqual((0..<6).map { label(merged, $0) },
                       ["A-1", "A-2", "A-3", "B-1", "B-2", "B-3"])
    }

    func testMergeReportsProgressToOne() throws {
        let a = try makeDocument(prefix: "A", pages: 2)
        let b = try makeDocument(prefix: "B", pages: 2)
        var last = 0.0
        _ = try PageOperations.merge([a, b], onProgress: { last = $0 })
        XCTAssertEqual(last, 1.0, accuracy: 0.0001, "progress should end at 100%")
    }

    func testMergeInterleaveAlternatesPages() throws {
        // The duplex-scan case: odds in one file, evens in another.
        let odds = try makeDocument(prefix: "ODD", pages: 3)   // pages 1,3,5
        let evens = try makeDocument(prefix: "EVEN", pages: 3)  // pages 2,4,6

        let merged = try PageOperations.merge([odds, evens], interleave: true)

        XCTAssertEqual(merged.pageCount, 6)
        XCTAssertEqual((0..<6).map { label(merged, $0) },
                       ["ODD-1", "EVEN-1", "ODD-2", "EVEN-2", "ODD-3", "EVEN-3"])
    }

    func testMergeInterleaveHandlesUnequalLengths() throws {
        let a = try makeDocument(prefix: "A", pages: 3)
        let b = try makeDocument(prefix: "B", pages: 1)

        let merged = try PageOperations.merge([a, b], interleave: true)

        XCTAssertEqual(merged.pageCount, 4)
        // A1, B1, then A's remaining pages tail out.
        XCTAssertEqual((0..<4).map { label(merged, $0) }, ["A-1", "B-1", "A-2", "A-3"])
    }

    func testMergeCancellationThrows() throws {
        let a = try makeDocument(prefix: "A", pages: 3)
        XCTAssertThrowsError(try PageOperations.merge([a], isCancelled: { true })) { error in
            XCTAssertEqual(error as? PageOperations.OperationError, .cancelled)
        }
    }

    // MARK: - Range parsing

    func testParseSinglePage() throws {
        XCTAssertEqual(try PageOperations.parsePageRanges("5", pageCount: 10), [[4]])
    }

    func testParseClosedRange() throws {
        XCTAssertEqual(try PageOperations.parsePageRanges("1-3", pageCount: 10), [[0, 1, 2]])
    }

    func testParseOpenEndedRange() throws {
        XCTAssertEqual(try PageOperations.parsePageRanges("8-", pageCount: 10), [[7, 8, 9]])
    }

    func testParseOpenStartRange() throws {
        XCTAssertEqual(try PageOperations.parsePageRanges("-3", pageCount: 10), [[0, 1, 2]])
    }

    func testParseMultipleSegments() throws {
        XCTAssertEqual(try PageOperations.parsePageRanges("1-3, 7, 10-", pageCount: 10),
                       [[0, 1, 2], [6], [9]])
    }

    func testParseRejectsOutOfBounds() {
        XCTAssertThrowsError(try PageOperations.parsePageRanges("11", pageCount: 10))
        XCTAssertThrowsError(try PageOperations.parsePageRanges("0", pageCount: 10))
        XCTAssertThrowsError(try PageOperations.parsePageRanges("3-1", pageCount: 10))
        XCTAssertThrowsError(try PageOperations.parsePageRanges("", pageCount: 10))
        XCTAssertThrowsError(try PageOperations.parsePageRanges("abc", pageCount: 10))
    }

    // MARK: - Split

    func testSplitByRangesProducesCorrectCountsAndContent() throws {
        let doc = try makeDocument(prefix: "P", pages: 10)

        let parts = try PageOperations.split(doc, ranges: "1-3, 7, 10-")

        XCTAssertEqual(parts.count, 3, "three segments → three documents")
        XCTAssertEqual(parts.map(\.pageCount), [3, 1, 1], "page counts per segment")
        XCTAssertEqual((0..<3).map { label(parts[0], $0) }, ["P-1", "P-2", "P-3"])
        XCTAssertEqual(label(parts[1], 0), "P-7")
        XCTAssertEqual(label(parts[2], 0), "P-10")
    }

    func testSplitEveryNChunksPages() throws {
        let doc = try makeDocument(prefix: "P", pages: 10)

        let parts = try PageOperations.split(doc, everyN: 4)

        XCTAssertEqual(parts.map(\.pageCount), [4, 4, 2], "10 pages / 4 → 4,4,2")
        XCTAssertEqual(label(parts[0], 0), "P-1")
        XCTAssertEqual(label(parts[2], 0), "P-9")
        XCTAssertEqual(label(parts[2], 1), "P-10")
    }

    func testSplitEveryNRejectsZero() throws {
        let doc = try makeDocument(prefix: "P", pages: 3)
        XCTAssertThrowsError(try PageOperations.split(doc, everyN: 0))
    }

    func testSplitByBookmarksSegmentsAtTopLevelEntries() throws {
        let doc = try makeDocument(prefix: "P", pages: 6)

        // Build a top-level outline: "Chapter 1" @ page 0, "Chapter 2" @ page 3.
        let root = PDFOutline()
        func bookmark(_ label: String, pageIndex: Int) -> PDFOutline {
            let node = PDFOutline()
            node.label = label
            if let page = doc.page(at: pageIndex) {
                node.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 400))
            }
            return node
        }
        root.insertChild(bookmark("Chapter 1", pageIndex: 0), at: 0)
        root.insertChild(bookmark("Chapter 2", pageIndex: 3), at: 1)
        doc.outlineRoot = root

        let parts = PageOperations.splitByBookmarks(doc)

        XCTAssertEqual(parts.count, 2, "two top-level bookmarks → two documents")
        XCTAssertEqual(parts.map(\.pageCount), [3, 3])
        XCTAssertEqual(label(parts[0], 0), "P-1")
        XCTAssertEqual(label(parts[1], 0), "P-4")
    }

    func testSplitByBookmarksReturnsEmptyWhenNoOutline() throws {
        let doc = try makeDocument(prefix: "P", pages: 3)
        XCTAssertTrue(PageOperations.splitByBookmarks(doc).isEmpty)
    }

    // MARK: - Extract

    func testExtractCopiesRequestedPagesInOrder() throws {
        let doc = try makeDocument(prefix: "P", pages: 5)
        let out = PageOperations.extract(doc, pages: [4, 0, 2])
        XCTAssertEqual(out.pageCount, 3)
        XCTAssertEqual((0..<3).map { label(out, $0) }, ["P-5", "P-1", "P-3"])
    }

    func testExtractSkipsOutOfBoundsIndices() throws {
        let doc = try makeDocument(prefix: "P", pages: 3)
        let out = PageOperations.extract(doc, pages: [0, 99, 1])
        XCTAssertEqual(out.pageCount, 2)
        XCTAssertEqual((0..<2).map { label(out, $0) }, ["P-1", "P-2"])
    }

    // MARK: - Blank page

    func testMakeBlankPageHasRequestedSize() throws {
        let page = try XCTUnwrap(PageOperations.makeBlankPage(size: PageOperations.BlankSize.a4))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 595, accuracy: 1)
        XCTAssertEqual(bounds.height, 842, accuracy: 1)
    }

    // MARK: - Round-trip fidelity (via dataRepresentation)

    func testMergedDocumentSurvivesSerialization() throws {
        let a = try makeDocument(prefix: "A", pages: 3)
        let b = try makeDocument(prefix: "B", pages: 3)
        let merged = try PageOperations.merge([a, b])
        let data = try XCTUnwrap(merged.dataRepresentation())
        let reloaded = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reloaded.pageCount, 6)
        XCTAssertEqual(label(reloaded, 3), "B-1")
    }
}
