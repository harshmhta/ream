import XCTest
import PDFKit
@testable import Ream

/// Tests for the dark-content document/page plumbing.
final class InvertingPDFDocumentTests: XCTestCase {

    /// Build an `InvertingPDFDocument` the way `PDFReferenceDocument` does — with
    /// the shared delegate installed, since that delegate is what vends
    /// `InvertingPDFPage` from `classForPage()`.
    private func makeInverting(pages: [String]) throws -> InvertingPDFDocument {
        let data = try XCTUnwrap(PDFTextFixture.makeDocument(pages: pages)?.dataRepresentation())
        let inverting = try XCTUnwrap(InvertingPDFDocument(data: data))
        inverting.delegate = AnnotationDocumentDelegate.shared
        return inverting
    }

    func testVendsInvertingPages() throws {
        let inverting = try makeInverting(pages: ["Hello world."])
        let page = try XCTUnwrap(inverting.page(at: 0))
        XCTAssertTrue(page is InvertingPDFPage,
                      "document delegate should vend InvertingPDFPage instances")
    }

    func testInvertFlagDefaultsOff() throws {
        let inverting = try makeInverting(pages: ["x"])
        XCTAssertFalse(inverting.invertContent)
    }

    /// Drawing with inversion off must not crash and must go through the stock
    /// path; drawing with it on must not crash either (exercises the CIFilter
    /// chain end-to-end).
    func testDrawingBothModesSucceeds() throws {
        let inverting = try makeInverting(pages: ["Hello world."])
        let page = try XCTUnwrap(inverting.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)

        for invert in [false, true] {
            inverting.invertContent = invert
            let renderer = NSImage(size: bounds.size, flipped: false) { _ in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                page.draw(with: .mediaBox, to: ctx)
                return true
            }
            XCTAssertTrue(renderer.size.width > 0)
        }
    }

    func testReferenceDocumentUsesInvertingDocument() {
        let doc = PDFReferenceDocument()
        XCTAssertTrue(doc.pdfDocument is InvertingPDFDocument)
    }

    func testInvertContentTogglePropagatesToDocument() {
        let doc = PDFReferenceDocument()
        doc.invertContent = true
        XCTAssertTrue((doc.pdfDocument as? InvertingPDFDocument)?.invertContent ?? false)
    }

    // MARK: - Page ops keep dark content working

    /// Pages inserted from another PDF arrive as plain `PDFPage`s (their source
    /// document has no Ream delegate), which would silently opt them out of
    /// dark-content rendering. The insert path has to re-vend them through this
    /// document so an inserted page inverts like every other page.
    @MainActor
    func testInsertedPagesAreInvertingPages() throws {
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try makeInverting(pages: ["Original page."])

        let foreign = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Inserted page."]))
        let foreignPage = try XCTUnwrap(foreign.page(at: 0))
        XCTAssertFalse(foreignPage is InvertingPDFPage, "precondition: the source page is a plain PDFPage")

        doc.insertPages([foreignPage], at: 1, undoManager: nil)

        XCTAssertEqual(doc.pdfDocument.pageCount, 2)
        let inserted = try XCTUnwrap(doc.pdfDocument.page(at: 1))
        XCTAssertTrue(inserted is InvertingPDFPage,
                      "an inserted page must render through the dark-content path like the rest")
        XCTAssertEqual(inserted.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Inserted page.")
    }

    /// Duplicating an existing page must not downgrade the copy to a plain page.
    @MainActor
    func testDuplicatedPagesStayInvertingPages() throws {
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try makeInverting(pages: ["A", "B"])

        doc.duplicatePages(at: IndexSet(integer: 0), undoManager: nil)

        XCTAssertEqual(doc.pdfDocument.pageCount, 3)
        XCTAssertTrue(try XCTUnwrap(doc.pdfDocument.page(at: 1)) is InvertingPDFPage)
    }
}
