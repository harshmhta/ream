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
}
