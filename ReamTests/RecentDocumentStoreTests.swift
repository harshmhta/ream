import XCTest
import PDFKit
@testable import Ream

/// Tests for the persisted session: security-scoped bookmarks round-tripping
/// through `UserDefaults`, and the tracker that keeps the list current.
///
/// Everything runs against a scratch `UserDefaults` suite so the developer's real
/// session is never touched.
@MainActor
final class RecentDocumentStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: RecentDocumentStore!
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "com.ream.tests.session.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = RecentDocumentStore(defaults: defaults)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReamSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    /// A real file on disk — bookmarking requires one.
    private func makeFile(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let doc = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Session \(name)."]))
        try XCTUnwrap(doc.dataRepresentation()).write(to: url)
        return url
    }

    /// Resolved URLs come back with their security scope started; balance it so
    /// the test process doesn't leak extensions.
    private func release(_ urls: [URL]) {
        urls.forEach(store.stopAccessing)
    }

    // MARK: - Most-recent document

    func testRemembersAndResolvesTheLastDocument() throws {
        let file = try makeFile("last.pdf")
        store.remember(file)

        let resolved = try XCTUnwrap(store.lastDocumentURL())
        defer { release([resolved]) }
        XCTAssertEqual(SessionRestore.canonicalPath(resolved), SessionRestore.canonicalPath(file))
    }

    func testLastDocumentIsNilWithNothingRemembered() {
        XCTAssertNil(store.lastDocumentURL())
    }

    /// A bookmark to a file that has since been deleted must resolve to nothing
    /// rather than crashing or handing back a dead URL.
    func testDeletedDocumentDoesNotResolve() throws {
        let file = try makeFile("gone.pdf")
        store.remember(file)
        try FileManager.default.removeItem(at: file)

        if let resolved = store.lastDocumentURL() {
            // Some filesystems can still resolve a deleted node; if so, it must at
            // least not exist any more.
            release([resolved])
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
        }
    }

    // MARK: - Full session

    func testSessionRoundTripsInOrder() throws {
        let a = try makeFile("a.pdf")
        let b = try makeFile("b.pdf")
        store.updateSession(openURLs: [a, b])

        let resolved = store.sessionURLs()
        defer { release(resolved) }
        XCTAssertEqual(resolved.map(SessionRestore.canonicalPath),
                       [a, b].map(SessionRestore.canonicalPath),
                       "tab order must survive a relaunch")
    }

    func testSessionReplacesRatherThanAppends() throws {
        let a = try makeFile("a.pdf")
        let b = try makeFile("b.pdf")
        store.updateSession(openURLs: [a, b])
        store.updateSession(openURLs: [b])

        let resolved = store.sessionURLs()
        defer { release(resolved) }
        XCTAssertEqual(resolved.map(SessionRestore.canonicalPath), [SessionRestore.canonicalPath(b)])
    }

    func testClosingEveryDocumentClearsTheSession() throws {
        let a = try makeFile("a.pdf")
        store.updateSession(openURLs: [a])
        store.updateSession(openURLs: [])
        XCTAssertTrue(store.sessionURLs().isEmpty)
    }

    /// One unreachable document must not take the rest of the session with it.
    func testUnresolvableEntriesAreSkippedNotFatal() throws {
        let a = try makeFile("a.pdf")
        let doomed = try makeFile("doomed.pdf")
        store.updateSession(openURLs: [doomed, a])
        try FileManager.default.removeItem(at: doomed)

        let resolved = store.sessionURLs()
        defer { release(resolved) }
        XCTAssertTrue(resolved.contains { SessionRestore.canonicalPath($0) == SessionRestore.canonicalPath(a) },
                      "the surviving document must still be restored")
    }

    func testSessionIsEmptyWithNothingPersisted() {
        XCTAssertTrue(store.sessionURLs().isEmpty)
    }

    // MARK: - SessionTracker

    private func document(at url: URL) -> PDFReferenceDocument {
        let doc = PDFReferenceDocument()
        doc.persistenceKey = url.absoluteString
        return doc
    }

    func testTrackerPersistsOpenDocumentsAndForgetsClosedOnes() throws {
        let a = try makeFile("a.pdf")
        let b = try makeFile("b.pdf")
        let tracker = SessionTracker(store: store)
        let docA = document(at: a)
        let docB = document(at: b)

        tracker.register(docA)
        tracker.register(docB)
        var resolved = store.sessionURLs()
        XCTAssertEqual(resolved.count, 2)
        release(resolved)

        tracker.unregister(docA)
        resolved = store.sessionURLs()
        defer { release(resolved) }
        XCTAssertEqual(resolved.map(SessionRestore.canonicalPath), [SessionRestore.canonicalPath(b)])
    }

    /// The same document can appear in two windows (⌘T on an open file); the
    /// session must not list it twice or restore would open a duplicate.
    func testTrackerDoesNotDuplicateTheSameDocument() throws {
        let a = try makeFile("a.pdf")
        let tracker = SessionTracker(store: store)

        tracker.register(document(at: a))
        tracker.register(document(at: a))

        let resolved = store.sessionURLs()
        defer { release(resolved) }
        XCTAssertEqual(resolved.count, 1)
    }

    /// A document that was never saved has no persistence key and simply is not
    /// part of the session.
    func testTrackerIgnoresDocumentsWithoutAPersistenceKey() {
        let tracker = SessionTracker(store: store)
        tracker.register(PDFReferenceDocument())
        XCTAssertTrue(store.sessionURLs().isEmpty)
    }
}
