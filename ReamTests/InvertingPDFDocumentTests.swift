import XCTest
import PDFKit
import ReamCore
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

    // MARK: - Wholesale document replacement keeps dark content working

    /// Strip All Metadata replaces `pdfDocument` with a rebuilt copy. If that
    /// rebuild is a plain `PDFDocument`, dark-content inversion silently stops
    /// working for the rest of the session (the page draw path keys off the
    /// document's type).
    @MainActor
    func testStripAllMetadataKeepsInvertingDocument() throws {
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try makeInverting(pages: ["Strip me."])
        doc.invertContent = true

        try doc.stripAllMetadata(undoManager: nil)

        let rebuilt = try XCTUnwrap(doc.pdfDocument as? InvertingPDFDocument)
        XCTAssertTrue(rebuilt.invertContent, "the window's invert setting must carry over")
        XCTAssertTrue(try XCTUnwrap(doc.pdfDocument.page(at: 0)) is InvertingPDFPage)
    }

    /// Same for Remove Password, which rebuilds the page tree to drop /Encrypt.
    @MainActor
    func testRemovePasswordKeepsInvertingDocument() throws {
        let source = PDFReferenceDocument()
        source.pdfDocument = try makeInverting(pages: ["Locked."])
        let encrypted = try PDFSecurityService.encryptedData(
            from: source.pdfDocument,
            settings: EncryptionSettings(userPassword: "open", ownerPassword: "owner"))

        let doc = PDFReferenceDocument()
        doc.pdfDocument = try XCTUnwrap(InvertingPDFDocument(data: encrypted))
        doc.pdfDocument.delegate = AnnotationDocumentDelegate.shared
        XCTAssertTrue(doc.unlock(withPassword: "open"))
        doc.invertContent = true

        try doc.removePassword(undoManager: nil)

        let rebuilt = try XCTUnwrap(doc.pdfDocument as? InvertingPDFDocument)
        XCTAssertTrue(rebuilt.invertContent)
        XCTAssertFalse(doc.pdfDocument.isEncrypted)
    }

    /// And for Flatten Annotations, which rebuilds the document from rasterized
    /// page content.
    @MainActor
    func testFlattenKeepsInvertingDocument() throws {
        let doc = PDFReferenceDocument()
        doc.pdfDocument = try makeInverting(pages: ["Flatten me."])
        doc.invertContent = true

        let flattened = try XCTUnwrap(FlattenService.flatten(doc.pdfDocument))
        doc.pdfDocument = flattened

        let rebuilt = try XCTUnwrap(doc.pdfDocument as? InvertingPDFDocument)
        XCTAssertTrue(rebuilt.invertContent)
        XCTAssertTrue(try XCTUnwrap(doc.pdfDocument.page(at: 0)) is InvertingPDFPage)
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
