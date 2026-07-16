import XCTest
@testable import ReamCore

final class DocumentMetadataTests: XCTestCase {

    func testEmptyMetadataHasNoIdentifyingData() {
        XCTAssertTrue(DocumentMetadata.empty.hasNoIdentifyingData)
        XCTAssertTrue(DocumentMetadata.empty.identifyingFields.isEmpty)
    }

    func testIdentifyingFieldsListsOnlyPopulatedFields() {
        let metadata = DocumentMetadata(
            title: "Report",
            author: "",              // empty → excluded
            subject: nil,            // nil → excluded
            keywords: ["a", "b"],
            creator: "Ream"
        )
        let labels = metadata.identifyingFields.map(\.label)
        XCTAssertEqual(labels, ["Title", "Keywords", "Application"])
        XCTAssertFalse(metadata.hasNoIdentifyingData)
    }

    func testKeywordsJoinForDisplay() {
        let metadata = DocumentMetadata(keywords: ["alpha", "beta", "gamma"])
        let keywordsField = metadata.identifyingFields.first { $0.label == "Keywords" }
        XCTAssertEqual(keywordsField?.value, "alpha, beta, gamma")
    }
}

final class DocumentPermissionsTests: XCTestCase {

    func testAllContainsEveryFlag() {
        let all = DocumentPermissions.all
        XCTAssertTrue(all.contains(.print))
        XCTAssertTrue(all.contains(.copy))
        XCTAssertTrue(all.contains(.edit))
        XCTAssertTrue(all.contains(.annotate))
    }

    func testNoneContainsNothing() {
        XCTAssertEqual(DocumentPermissions.none, [])
        XCTAssertFalse(DocumentPermissions.none.contains(.print))
    }

    func testEncryptionSettingsNormalizeEmptyStringsToNil() {
        let settings = EncryptionSettings(userPassword: "", ownerPassword: "  owner ")
        let normalized = settings.normalized
        XCTAssertNil(normalized.userPassword)
        XCTAssertEqual(normalized.ownerPassword, "  owner ")  // only empties drop; content kept verbatim
    }

    func testHasAnyPasswordReflectsNormalizedState() {
        XCTAssertFalse(EncryptionSettings(userPassword: "", ownerPassword: "").hasAnyPassword)
        XCTAssertFalse(EncryptionSettings().hasAnyPassword)
        XCTAssertTrue(EncryptionSettings(userPassword: "open").hasAnyPassword)
        XCTAssertTrue(EncryptionSettings(ownerPassword: "own").hasAnyPassword)
    }

    func testPasswordsAreASCIIRejectsNonASCII() {
        XCTAssertTrue(EncryptionSettings(userPassword: "plainpass123").passwordsAreASCII)
        XCTAssertTrue(EncryptionSettings().passwordsAreASCII)  // no password → trivially ok
        XCTAssertFalse(EncryptionSettings(userPassword: "café").passwordsAreASCII)
        XCTAssertFalse(EncryptionSettings(ownerPassword: "pass🔒").passwordsAreASCII)
        // A non-ASCII owner password fails even when the user password is fine.
        XCTAssertFalse(EncryptionSettings(userPassword: "ok", ownerPassword: "naïve").passwordsAreASCII)
    }
}
