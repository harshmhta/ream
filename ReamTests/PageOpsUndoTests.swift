import XCTest
import PDFKit
import AppKit
@testable import Ream

/// Tests for the undoable in-place page mutations on ``PDFReferenceDocument``.
///
/// Each op is exercised through a real `UndoManager` and then undone (and, where
/// it matters, redone) to prove the inverse restores exact page order, count,
/// and rotation — the "full undo support for every page op" requirement.
@MainActor
final class PageOpsUndoTests: XCTestCase {

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

    private func makeRefDocument(prefix: String, pages count: Int) throws -> PDFReferenceDocument {
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try makeDocument(prefix: prefix, pages: count)
        return doc
    }

    private func labels(_ doc: PDFReferenceDocument) -> [String] {
        (0..<doc.pdfDocument.pageCount).map {
            doc.pdfDocument.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    // MARK: - Delete

    func testDeleteAndUndoRestoresPages() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 4)
        let undo = UndoManager()

        doc.deletePages(at: IndexSet(integer: 1), undoManager: undo)
        XCTAssertEqual(labels(doc), ["P-1", "P-3", "P-4"])

        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(labels(doc), ["P-1", "P-2", "P-3", "P-4"], "undo must restore the deleted page in place")

        XCTAssertTrue(undo.canRedo)
        undo.redo()
        XCTAssertEqual(labels(doc), ["P-1", "P-3", "P-4"], "redo must re-apply the delete")
    }

    func testDeleteRefusesToEmptyDocument() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 2)
        let undo = UndoManager()
        doc.deletePages(at: IndexSet([0, 1]), undoManager: undo)
        XCTAssertEqual(doc.pdfDocument.pageCount, 2, "must not delete every page")
        XCTAssertFalse(undo.canUndo, "a refused op registers no undo")
    }

    // MARK: - Duplicate

    func testDuplicateAndUndo() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 3)
        let undo = UndoManager()

        doc.duplicatePages(at: IndexSet(integer: 0), undoManager: undo)
        XCTAssertEqual(labels(doc), ["P-1", "P-1", "P-2", "P-3"], "copy lands right after the original")

        undo.undo()
        XCTAssertEqual(labels(doc), ["P-1", "P-2", "P-3"])
    }

    // MARK: - Rotate

    func testRotateAndUndoRestoresRotation() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 2)
        let undo = UndoManager()
        let page0 = try XCTUnwrap(doc.pdfDocument.page(at: 0))
        let original = page0.rotation

        doc.rotatePages(at: IndexSet(integer: 0), by: 90, undoManager: undo)
        XCTAssertEqual(page0.rotation, (original + 90) % 360)

        undo.undo()
        XCTAssertEqual(doc.pdfDocument.page(at: 0)?.rotation, original, "undo restores original rotation")
    }

    func testRotateCounterClockwiseNormalizes() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 1)
        let undo = UndoManager()
        doc.rotatePages(at: IndexSet(integer: 0), by: -90, undoManager: undo)
        XCTAssertEqual(doc.pdfDocument.page(at: 0)?.rotation, 270, "-90 normalizes to 270")
    }

    // MARK: - Move

    func testMovePageForwardAndUndo() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 4)
        let undo = UndoManager()

        // Move page 1 (index 0) to the end.
        doc.movePages(from: IndexSet(integer: 0), to: 4, undoManager: undo)
        XCTAssertEqual(labels(doc), ["P-2", "P-3", "P-4", "P-1"])

        undo.undo()
        XCTAssertEqual(labels(doc), ["P-1", "P-2", "P-3", "P-4"])
    }

    func testMovePageBackward() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 4)
        let undo = UndoManager()

        // Move page 4 (index 3) to the front (destination 0).
        doc.movePages(from: IndexSet(integer: 3), to: 0, undoManager: undo)
        XCTAssertEqual(labels(doc), ["P-4", "P-1", "P-2", "P-3"])
    }

    func testMoveMultipleContiguous() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 5)
        let undo = UndoManager()

        // Move pages 1&2 (indices 0,1) to after page 4 (destination 4).
        doc.movePages(from: IndexSet([0, 1]), to: 4, undoManager: undo)
        XCTAssertEqual(labels(doc), ["P-3", "P-4", "P-1", "P-2", "P-5"])

        undo.undo()
        XCTAssertEqual(labels(doc), ["P-1", "P-2", "P-3", "P-4", "P-5"])
    }

    // MARK: - Insert

    func testInsertBlankPageAndUndo() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 2)
        let undo = UndoManager()
        let blank = try XCTUnwrap(PageOperations.makeBlankPage(size: PageOperations.BlankSize.usLetter))

        doc.insertPages([blank], at: 1, undoManager: undo, actionName: "Insert Blank Page")
        XCTAssertEqual(doc.pdfDocument.pageCount, 3)
        XCTAssertEqual(labels(doc)[0], "P-1")
        XCTAssertEqual(labels(doc)[2], "P-2", "original page 2 shifts to index 2")

        undo.undo()
        XCTAssertEqual(doc.pdfDocument.pageCount, 2)
        XCTAssertEqual(labels(doc), ["P-1", "P-2"])
    }

    func testInsertPagesFromAnotherDocument() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 2)
        let source = try makeDocument(prefix: "X", pages: 2)
        let undo = UndoManager()
        let pages = [source.page(at: 0), source.page(at: 1)].compactMap { $0 }

        doc.insertPages(pages, at: 2, undoManager: undo, actionName: "Insert Pages")
        XCTAssertEqual(labels(doc), ["P-1", "P-2", "X-1", "X-2"])

        undo.undo()
        XCTAssertEqual(labels(doc), ["P-1", "P-2"])
    }

    // MARK: - Undo action names

    func testUndoActionNameIsSet() throws {
        let doc = try makeRefDocument(prefix: "P", pages: 3)
        let undo = UndoManager()
        doc.rotatePages(at: IndexSet(integer: 0), by: 90, undoManager: undo)
        XCTAssertEqual(undo.undoActionName, "Rotate Page")
    }
}
