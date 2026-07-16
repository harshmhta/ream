import XCTest
import PDFKit
@testable import Ream
import ReamCore

/// Document-model integration: metadata edits, encryption-at-save, strip, and
/// remove-password flowing through `PDFReferenceDocument.snapshot()`.
@MainActor
final class PDFReferenceDocumentSecurityTests: XCTestCase {

    private func makeDocument(fixture: String = "sample") throws -> PDFReferenceDocument {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: fixture, withExtension: "pdf") else {
            throw XCTSkip("\(fixture).pdf fixture not found")
        }
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let doc = PDFReferenceDocument()
        doc.pdfDocument = pdf
        return doc
    }

    func testUpdateMetadataThenSnapshotRoundTrips() throws {
        let doc = try makeDocument()
        var metadata = doc.metadata
        metadata.title = "Model Title"
        metadata.author = "Model Author"
        doc.updateMetadata(metadata, undoManager: nil)

        let snapshot = try doc.snapshot(contentType: .pdf)
        let reloaded = try XCTUnwrap(PDFDocument(data: snapshot))
        let readBack = PDFMetadataService.read(from: reloaded)
        XCTAssertEqual(readBack.title, "Model Title")
        XCTAssertEqual(readBack.author, "Model Author")
    }

    func testSnapshotEncryptsWhenEncryptionSet() throws {
        let doc = try makeDocument()
        doc.setEncryption(EncryptionSettings(userPassword: "open", ownerPassword: "owner"),
                          undoManager: nil)

        let snapshot = try doc.snapshot(contentType: .pdf)
        let reopened = try XCTUnwrap(PDFDocument(data: snapshot))
        XCTAssertTrue(reopened.isEncrypted)
        XCTAssertTrue(reopened.isLocked)
        XCTAssertTrue(reopened.unlock(withPassword: "open"))
    }

    func testSnapshotIsPlaintextWhenNoEncryption() throws {
        let doc = try makeDocument()
        let snapshot = try doc.snapshot(contentType: .pdf)
        let reopened = try XCTUnwrap(PDFDocument(data: snapshot))
        XCTAssertFalse(reopened.isEncrypted)
    }

    func testStripAllMetadataReplacesDocument() throws {
        let doc = try makeDocument(fixture: "xmp_sample")
        XCTAssertEqual(doc.metadata.title, "Secret Info Title")

        try doc.stripAllMetadata(undoManager: nil)

        XCTAssertNil(doc.metadata.title)
        XCTAssertNil(doc.metadata.author)
        let snapshot = try doc.snapshot(contentType: .pdf)
        XCTAssertNil(PDFXMPService.rawXMP(fromData: snapshot))
    }

    func testUndoRestoresMetadata() throws {
        let undo = UndoManager()
        // Disable automatic per-event grouping so each edit is an independent
        // undo step. In the running app, edits happen in separate run-loop
        // cycles (distinct groups); a test issues them synchronously, which
        // would otherwise coalesce them into one group.
        undo.groupsByEvent = false
        let doc = try makeDocument()
        var metadata = doc.metadata

        undo.beginUndoGrouping()
        metadata.title = "Before"
        doc.updateMetadata(metadata, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(doc.metadata.title, "Before")

        undo.beginUndoGrouping()
        metadata.title = "After"
        doc.updateMetadata(metadata, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertEqual(doc.metadata.title, "After")

        undo.undo()
        XCTAssertEqual(doc.metadata.title, "Before", "undo should revert the most recent edit")
    }

    func testCanRemovePasswordReflectsEncryptionState() throws {
        let doc = try makeDocument()
        XCTAssertFalse(doc.canRemovePassword, "plaintext doc has nothing to remove")

        doc.setEncryption(EncryptionSettings(userPassword: "pw"), undoManager: nil)
        XCTAssertTrue(doc.canRemovePassword, "pending encryption can be removed")
    }

    func testRemovePasswordClearsPendingEncryption() throws {
        let doc = try makeDocument()
        doc.setEncryption(EncryptionSettings(userPassword: "pw"), undoManager: nil)
        XCTAssertNotNil(doc.encryptionSettings)

        try doc.removePassword(undoManager: nil)
        XCTAssertNil(doc.encryptionSettings)

        let snapshot = try doc.snapshot(contentType: .pdf)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(data: snapshot)).isEncrypted)
    }

    func testRemovePasswordDecryptsLoadedEncryptedDocument() throws {
        // Start from a genuinely encrypted-on-disk document.
        let base = try makeDocument()
        let encrypted = try PDFSecurityService.encryptedData(
            from: base.pdfDocument,
            settings: EncryptionSettings(userPassword: "open", ownerPassword: "owner")
        )
        let loaded = PDFReferenceDocument()
        loaded.pdfDocument = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(loaded.isLocked)

        // Unlock, then remove password.
        XCTAssertTrue(loaded.unlock(withPassword: "open"))
        XCTAssertTrue(loaded.canRemovePassword)
        try loaded.removePassword(undoManager: nil)

        let snapshot = try loaded.snapshot(contentType: .pdf)
        let plain = try XCTUnwrap(PDFDocument(data: snapshot))
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertEqual(plain.pageCount, base.pdfDocument.pageCount)
    }
}
