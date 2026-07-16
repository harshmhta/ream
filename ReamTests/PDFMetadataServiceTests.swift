import XCTest
import PDFKit
@testable import Ream
import ReamCore

/// Metadata read/write + strip behavior, including the brief-required
/// title/author round-trip and "Info dict empty + XMP scrubbed" assertions.
final class PDFMetadataServiceTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> PDFDocument {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "pdf") else {
            throw XCTSkip("\(name).pdf fixture not found in test bundle")
        }
        return try XCTUnwrap(PDFDocument(url: url))
    }

    // MARK: - Round-trip (brief requirement)

    func testTitleAndAuthorRoundTrip() throws {
        let doc = try loadFixture("sample")
        var metadata = PDFMetadataService.read(from: doc)
        metadata.title = "Round Trip Title"
        metadata.author = "Ada Lovelace"
        PDFMetadataService.apply(metadata, to: doc)

        // Serialize + reload, exactly as a save/reopen would.
        let data = try XCTUnwrap(doc.dataRepresentation())
        let reloaded = try XCTUnwrap(PDFDocument(data: data))
        let readBack = PDFMetadataService.read(from: reloaded)

        XCTAssertEqual(readBack.title, "Round Trip Title")
        XCTAssertEqual(readBack.author, "Ada Lovelace")
    }

    func testSubjectAndKeywordsRoundTrip() throws {
        let doc = try loadFixture("sample")
        var metadata = PDFMetadataService.read(from: doc)
        metadata.subject = "Quarterly figures"
        metadata.keywords = ["finance", "q3", "internal"]
        PDFMetadataService.apply(metadata, to: doc)

        let data = try XCTUnwrap(doc.dataRepresentation())
        let reloaded = try XCTUnwrap(PDFDocument(data: data))
        let readBack = PDFMetadataService.read(from: reloaded)

        XCTAssertEqual(readBack.subject, "Quarterly figures")
        XCTAssertEqual(readBack.keywords, ["finance", "q3", "internal"])
    }

    func testEmptyFieldClearsInfoKey() throws {
        let doc = try loadFixture("sample")
        var metadata = PDFMetadataService.read(from: doc)
        metadata.title = "Temporary"
        PDFMetadataService.apply(metadata, to: doc)
        XCTAssertEqual(PDFMetadataService.read(from: doc).title, "Temporary")

        // Now clear it.
        metadata.title = ""
        PDFMetadataService.apply(metadata, to: doc)
        XCTAssertNil(PDFMetadataService.read(from: doc).title)
    }

    // MARK: - Strip (brief requirement: Info empty + XMP scrubbed)

    func testStripClearsInfoDictionary() throws {
        let doc = try loadFixture("xmp_sample")
        // Sanity: the fixture starts with identifying Info data.
        let before = PDFMetadataService.read(from: doc)
        XCTAssertEqual(before.title, "Secret Info Title")
        XCTAssertEqual(before.author, "Secret Info Author")

        let strippedData = try PDFSecurityService.strippedData(from: doc)
        let stripped = try XCTUnwrap(PDFDocument(data: strippedData))
        let after = PDFMetadataService.read(from: stripped)

        XCTAssertNil(after.title, "Title must be gone after strip")
        XCTAssertNil(after.author, "Author must be gone after strip")
        XCTAssertNil(after.subject)
        XCTAssertTrue(after.keywords.isEmpty)
        XCTAssertNil(after.creator)
    }

    func testStripScrubsXMPMetadataStream() throws {
        let doc = try loadFixture("xmp_sample")
        // Sanity: the fixture has a catalog XMP stream carrying secret values.
        let rawBefore = try XCTUnwrap(PDFXMPService.rawXMP(from: doc))
        XCTAssertTrue(rawBefore.contains("Secret XMP Author"))

        let strippedData = try PDFSecurityService.strippedData(from: doc)

        // The scrubbed output must have NO catalog /Metadata stream at all — a
        // byte search alone is insufficient because PDFKit re-emits XMP flate-
        // compressed, so we assert via the CoreGraphics catalog accessor.
        XCTAssertNil(PDFXMPService.rawXMP(fromData: strippedData),
                     "stripped document must have no XMP metadata stream")

        // And the raw bytes must not contain the secret plaintext either.
        let secret = try XCTUnwrap("Secret XMP Author".data(using: .isoLatin1))
        XCTAssertNil(strippedData.range(of: secret),
                     "secret XMP author must not survive in the bytes")
    }

    func testStripPreservesPageCount() throws {
        let doc = try loadFixture("sample")
        let originalPages = doc.pageCount
        let strippedData = try PDFSecurityService.strippedData(from: doc)
        let stripped = try XCTUnwrap(PDFDocument(data: strippedData))
        XCTAssertEqual(stripped.pageCount, originalPages, "strip must not drop pages")
    }

    func testStripRemovesAnnotations() throws {
        let doc = try loadFixture("sample")
        let page = try XCTUnwrap(doc.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
            forType: .freeText, withProperties: nil
        )
        annotation.contents = "confidential reviewer note"
        page.addAnnotation(annotation)
        XCTAssertEqual(page.annotations.count, 1)

        let strippedData = try PDFSecurityService.strippedData(from: doc)
        let stripped = try XCTUnwrap(PDFDocument(data: strippedData))
        XCTAssertEqual(stripped.page(at: 0)?.annotations.count, 0,
                       "strip must remove annotations/comments")

        let secret = try XCTUnwrap("confidential reviewer note".data(using: .isoLatin1))
        XCTAssertNil(strippedData.range(of: secret))
    }
}
