import XCTest
@testable import Ream

/// Tests for "reopen last session": what gets reopened, what gets skipped, and —
/// the easy thing to get wrong — what still has to have its security scope
/// released even though it is never opened.
final class SessionRestoreTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - Planning

    func testOpensEverySessionDocumentWhenNothingIsOnScreen() {
        let urls = [url("/tmp/a.pdf"), url("/tmp/b.pdf")]
        let plan = SessionRestore.plan(sessionURLs: urls, alreadyOpen: [])
        XCTAssertEqual(plan.open, urls, "order must follow the session")
        XCTAssertTrue(plan.release.isEmpty)
    }

    /// macOS restores windows itself when window restoration is on. Reopening
    /// those would double every window — the bug this filter exists for.
    func testSkipsDocumentsAlreadyOnScreen() {
        let restored = url("/tmp/a.pdf")
        let plan = SessionRestore.plan(
            sessionURLs: [restored, url("/tmp/b.pdf")],
            alreadyOpen: [SessionRestore.canonicalPath(restored)])

        XCTAssertEqual(plan.open, [url("/tmp/b.pdf")])
        XCTAssertEqual(plan.release, [restored],
                       "a skipped document still holds the scope the bookmark resolve started")
    }

    /// Every resolved URL owns a started security scope, so a URL we choose not
    /// to open has to be released explicitly. Nothing else will do it, and the
    /// process leaks a sandbox extension per already-restored document per
    /// launch otherwise.
    func testEverySessionURLIsEitherOpenedOrReleased() {
        let urls = [url("/tmp/a.pdf"), url("/tmp/b.pdf"), url("/tmp/c.pdf"), url("/tmp/a.pdf")]
        let plan = SessionRestore.plan(
            sessionURLs: urls,
            alreadyOpen: [SessionRestore.canonicalPath(url("/tmp/c.pdf"))])

        XCTAssertEqual(plan.open.count + plan.release.count, urls.count)
        XCTAssertEqual(Set(plan.open.map(SessionRestore.canonicalPath))
                        .intersection(plan.release.map(SessionRestore.canonicalPath)).count, 1,
                       "the duplicate /tmp/a.pdf appears on both sides — opened once, released once")
    }

    /// Two bookmarks can resolve to the same file, and a duplicate must not open
    /// a second window for it.
    func testDuplicatesWithinTheSessionCollapse() {
        let plan = SessionRestore.plan(
            sessionURLs: [url("/tmp/a.pdf"), url("/tmp/a.pdf")],
            alreadyOpen: [])
        XCTAssertEqual(plan.open, [url("/tmp/a.pdf")])
        XCTAssertEqual(plan.release, [url("/tmp/a.pdf")])
    }

    /// Two paths can name the same file through a symlinked directory (on macOS
    /// `/tmp` → `/private/tmp` is exactly this), and a path can carry `.` / `..`.
    /// Comparison has to see through both or a restored document reopens.
    func testCanonicalPathResolvesSymlinksAndDotSegments() throws {
        let (real, link) = try makeSymlinkedDirectory()
        let file = real.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)

        let plain = SessionRestore.canonicalPath(file)
        XCTAssertEqual(SessionRestore.canonicalPath(link.appendingPathComponent("doc.pdf")), plain,
                       "the same file reached through a symlinked directory must compare equal")
        XCTAssertEqual(SessionRestore.canonicalPath(real.appendingPathComponent("./doc.pdf")), plain)
        XCTAssertEqual(SessionRestore.canonicalPath(real.appendingPathComponent("sub/../doc.pdf")), plain)
    }

    func testAlreadyOpenComparisonUsesCanonicalPaths() throws {
        let (real, link) = try makeSymlinkedDirectory()
        let file = real.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)

        let plan = SessionRestore.plan(
            sessionURLs: [file],
            alreadyOpen: [SessionRestore.canonicalPath(link.appendingPathComponent("doc.pdf"))])

        XCTAssertTrue(plan.open.isEmpty, "the same file by another path must count as already open")
        XCTAssertEqual(plan.release.count, 1, "and must still have its security scope released")
    }

    /// A scratch directory plus a symlink pointing at it, both cleaned up after.
    /// (The test bundle runs inside the app sandbox, so this lives in the
    /// container's temp directory rather than `/tmp`.)
    private func makeSymlinkedDirectory() throws -> (real: URL, link: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReamSessionRestore-\(UUID().uuidString)")
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        let fm = FileManager.default
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        addTeardownBlock { try? fm.removeItem(at: root) }
        return (real, link)
    }

    func testEmptySessionPlansNothing() {
        let plan = SessionRestore.plan(sessionURLs: [], alreadyOpen: ["/tmp/a.pdf"])
        XCTAssertTrue(plan.open.isEmpty)
        XCTAssertTrue(plan.release.isEmpty)
    }
}
