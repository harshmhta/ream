import XCTest
import PDFKit
import UniformTypeIdentifiers
@testable import Ream

/// Tests for the document model — proving we can load a real PDF and that the
/// no-op save round-trip preserves page structure (the "fidelity" contract).
final class PDFReferenceDocumentTests: XCTestCase {

    /// Locate the bundled sample PDF fixture.
    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "sample", withExtension: "pdf") else {
            throw XCTSkip("sample.pdf fixture not found in test bundle")
        }
        return try Data(contentsOf: url)
    }

    func testLoadsSamplePDF() throws {
        let data = try fixtureData()
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(doc.pageCount, 0, "sample fixture should have at least one page")
    }

    func testReadableAndWritableTypesArePDF() {
        XCTAssertEqual(PDFReferenceDocument.readableContentTypes, [.pdf])
        XCTAssertEqual(PDFReferenceDocument.writableContentTypes, [.pdf])
    }

    func testSnapshotRoundTripPreservesPageCount() throws {
        let data = try fixtureData()
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let originalPageCount = pdf.pageCount

        let doc = PDFReferenceDocument()
        doc.pdfDocument = pdf

        let snapshot = try doc.snapshot(contentType: .pdf)
        let reloaded = try XCTUnwrap(PDFDocument(data: snapshot))
        XCTAssertEqual(reloaded.pageCount, originalPageCount,
                       "no-op save must preserve every page")
    }
}
