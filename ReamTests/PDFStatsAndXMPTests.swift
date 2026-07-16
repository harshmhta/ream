import XCTest
import PDFKit
@testable import Ream

/// Read-only stats + XMP parsing for the Document Properties dialog.
final class PDFStatsAndXMPTests: XCTestCase {

    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "pdf") else {
            throw XCTSkip("\(name).pdf fixture not found")
        }
        return url
    }

    func testStatsReportPageCountAndVersion() throws {
        let url = try fixtureURL("sample")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let stats = PDFStatsService.stats(for: doc, fileURL: url)

        XCTAssertEqual(stats.pageCount, doc.pageCount)
        XCTAssertGreaterThan(stats.pageCount, 0)
        XCTAssertFalse(stats.pdfVersion.isEmpty)
        XCTAssertNotNil(stats.fileSizeBytes)
        XCTAssertNotEqual(stats.fileSizeDisplay, "—")
    }

    func testStatsReportEncryptedFlag() throws {
        let url = try fixtureURL("sample")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let plainStats = PDFStatsService.stats(for: doc, fileURL: url)
        XCTAssertFalse(plainStats.isEncrypted)

        let encrypted = try PDFSecurityService.encryptedData(
            from: doc, settings: .init(userPassword: "pw", ownerPassword: "own")
        )
        let encDoc = try XCTUnwrap(PDFDocument(data: encrypted))
        let encStats = PDFStatsService.stats(for: encDoc, fileURL: nil)
        XCTAssertTrue(encStats.isEncrypted)
    }

    func testXMPEntriesParsedFromFixture() throws {
        let url = try fixtureURL("xmp_sample")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let entries = PDFXMPService.entries(from: doc)

        XCTAssertFalse(entries.isEmpty, "xmp_sample has a catalog XMP stream")
        let title = entries.first { $0.key == "Title" }
        let creator = entries.first { $0.key == "Creator" }
        XCTAssertEqual(title?.value, "Secret XMP Title")
        XCTAssertEqual(creator?.value, "Secret XMP Author")
    }

    func testXMPEntriesEmptyWhenNoMetadataStream() throws {
        let url = try fixtureURL("sample")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        // sample.pdf (Quartz-produced) has no catalog XMP → no entries.
        XCTAssertTrue(PDFXMPService.entries(from: doc).isEmpty)
    }

    func testRawXMPRoundTripFromData() throws {
        let url = try fixtureURL("xmp_sample")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(PDFXMPService.rawXMP(fromData: data))
        XCTAssertTrue(raw.contains("xmpmeta"))
        XCTAssertTrue(raw.contains("Secret XMP Title"))
    }
}
