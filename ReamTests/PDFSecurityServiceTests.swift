import XCTest
import PDFKit
@testable import Ream
import ReamCore

/// Encryption / decryption behavior, including the brief-required
/// "encrypt with a password, close, reopen with password, assert readable".
final class PDFSecurityServiceTests: XCTestCase {

    private func loadFixture(_ name: String = "sample") throws -> PDFDocument {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "pdf") else {
            throw XCTSkip("\(name).pdf fixture not found in test bundle")
        }
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func contains(_ token: String, in data: Data) -> Bool {
        guard let needle = token.data(using: .isoLatin1) else { return false }
        return data.range(of: needle) != nil
    }

    // MARK: - Encrypt → reopen → unlock (brief requirement)

    func testEncryptReopenUnlockRoundTrip() throws {
        let doc = try loadFixture()
        let originalPages = doc.pageCount

        let settings = EncryptionSettings(userPassword: "letmein", ownerPassword: "adminpass")
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        // Reopen: should be encrypted and locked, no pages readable yet.
        let reopened = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(reopened.isEncrypted)
        XCTAssertTrue(reopened.isLocked)

        // Unlock with the open password → readable.
        XCTAssertTrue(reopened.unlock(withPassword: "letmein"))
        XCTAssertFalse(reopened.isLocked)
        XCTAssertEqual(reopened.pageCount, originalPages)
    }

    func testWrongPasswordStaysLocked() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(userPassword: "correct")
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        let reopened = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertFalse(reopened.unlock(withPassword: "wrong"))
        XCTAssertTrue(reopened.isLocked)
    }

    func testEncryptWithNoPasswordThrows() throws {
        let doc = try loadFixture()
        XCTAssertThrowsError(try PDFSecurityService.encryptedData(from: doc, settings: EncryptionSettings())) { error in
            XCTAssertEqual(error as? PDFSecurityService.SecurityError, .noPasswordProvided)
        }
    }

    // MARK: - Encryption strength (documents the AES-128 reality)

    func testEncryptionUsesAES() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(userPassword: "pw", ownerPassword: "own")
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        XCTAssertTrue(contains("/Encrypt", in: encrypted) || contains("/Filter", in: encrypted))
        // Native writer emits AES-128 (AESV2). This asserts we are using AES (not
        // legacy RC4) — the strongest the native writer supports. AES-256
        // (AESV3) is a tracked follow-up requiring a non-native dependency.
        XCTAssertTrue(contains("AESV2", in: encrypted) || contains("AESV3", in: encrypted),
                      "encryption should be AES, not RC4")
    }

    // MARK: - Permission flags

    func testDenyingPrintAndCopyIsEnforcedForUser() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(
            userPassword: "open",
            ownerPassword: "owner",
            permissions: []   // deny everything
        )
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        let reopened = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(reopened.unlock(withPassword: "open"))
        XCTAssertFalse(reopened.allowsPrinting, "printing should be denied")
        XCTAssertFalse(reopened.allowsCopying, "copying should be denied")
    }

    func testOwnerPasswordGrantsFullAccessDespiteRestrictions() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(
            userPassword: "open",
            ownerPassword: "owner",
            permissions: []
        )
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        let asOwner = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(asOwner.unlock(withPassword: "owner"))
        XCTAssertTrue(asOwner.allowsPrinting, "owner bypasses restrictions")
        XCTAssertTrue(asOwner.allowsCopying)
    }

    func testAllowingPrintOnlyPermitsPrintNotCopy() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(
            userPassword: "open",
            ownerPassword: "owner",
            permissions: [.print]
        )
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        let reopened = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(reopened.unlock(withPassword: "open"))
        XCTAssertTrue(reopened.allowsPrinting)
        XCTAssertFalse(reopened.allowsCopying)
    }

    // MARK: - Remove password / decrypt

    func testRemovePasswordProducesPlaintextCopy() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(userPassword: "secret", ownerPassword: "owner")
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        // Simulate the user opening + unlocking, then removing the password.
        let unlocked = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(unlocked.unlock(withPassword: "secret"))

        let decrypted = try PDFSecurityService.decryptedData(from: unlocked)
        let plain = try XCTUnwrap(PDFDocument(data: decrypted))
        XCTAssertFalse(plain.isEncrypted, "removed-password copy must be unencrypted")
        XCTAssertFalse(plain.isLocked)
        XCTAssertEqual(plain.pageCount, doc.pageCount)
        XCTAssertFalse(contains("/Encrypt", in: decrypted))
    }

    func testDecryptLockedDocumentThrows() throws {
        let doc = try loadFixture()
        let settings = EncryptionSettings(userPassword: "secret")
        let encrypted = try PDFSecurityService.encryptedData(from: doc, settings: settings)

        // Still locked (never unlocked) → decrypt must refuse.
        let locked = try XCTUnwrap(PDFDocument(data: encrypted))
        XCTAssertTrue(locked.isLocked)
        XCTAssertThrowsError(try PDFSecurityService.decryptedData(from: locked)) { error in
            XCTAssertEqual(error as? PDFSecurityService.SecurityError, .documentLocked)
        }
    }

    // MARK: - Permission mapping

    func testAccessPermissionsRawValueSupersets() {
        // "edit" should also grant assembly; "copy" should also grant accessibility.
        let editRaw = PDFSecurityService.accessPermissionsRawValue(from: [.edit])
        XCTAssertNotEqual(editRaw & PDFAccessPermissions.allowsDocumentChanges.rawValue, 0)
        XCTAssertNotEqual(editRaw & PDFAccessPermissions.allowsDocumentAssembly.rawValue, 0)

        let noneRaw = PDFSecurityService.accessPermissionsRawValue(from: [])
        XCTAssertEqual(noneRaw, 0)
    }
}
