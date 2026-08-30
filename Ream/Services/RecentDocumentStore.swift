import Foundation

/// Remembers open documents so the app can restore the last session on the next
/// launch if the system did not restore windows itself.
///
/// Under the App Sandbox we cannot simply stash a path and reopen it later — the
/// sandbox would deny access. We persist **security-scoped bookmarks** and
/// resolve them on relaunch to regain permission to the files the user chose.
///
/// Two levels of memory:
/// - `remember(_:)` / `lastDocumentURL()` — the single most-recent file, kept for
///   backwards compatibility with the foundation's reopen-last behaviour.
/// - `updateSession(openURLs:)` / `sessionURLs()` — the full set of currently-open
///   documents, so relaunch can restore every tab.
final class RecentDocumentStore {
    static let shared = RecentDocumentStore()

    private let defaults: UserDefaults
    private let bookmarkKey = "com.ream.app.lastDocumentBookmark"
    private let sessionKey = "com.ream.app.sessionBookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Single most-recent document

    /// Persist a security-scoped bookmark to `url` as the last-opened document.
    func remember(_ url: URL) {
        if let bookmark = makeBookmark(for: url) {
            defaults.set(bookmark, forKey: bookmarkKey)
        }
    }

    /// Resolve and return the last-opened document URL, if one exists and is
    /// still reachable. The returned URL already had its security scope started;
    /// balance it with `stopAccessing(_:)` after opening.
    func lastDocumentURL() -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        guard let (url, isStale) = resolve(bookmark) else { return nil }
        if isStale, let fresh = makeBookmark(for: url) {
            defaults.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    // MARK: - Full session (all open tabs/windows)

    /// Replace the persisted session with the given set of open document URLs.
    func updateSession(openURLs: [URL]) {
        let bookmarks = openURLs.compactMap { makeBookmark(for: $0) }
        defaults.set(bookmarks, forKey: sessionKey)
    }

    /// Resolve every document from the last session that is still reachable.
    /// Returned URLs have had their security scope started for immediate opening;
    /// the caller must balance that with `stopAccessing(_:)` once the document is
    /// open. Any bookmark that resolves stale is rewritten so the session keeps
    /// reopening across file moves / OS updates.
    func sessionURLs() -> [URL] {
        guard let bookmarks = defaults.array(forKey: sessionKey) as? [Data] else { return [] }
        var refreshed = bookmarks
        var didRefresh = false
        var urls: [URL] = []
        for (index, bookmark) in bookmarks.enumerated() {
            guard let (url, isStale) = resolve(bookmark) else { continue }
            urls.append(url)
            if isStale, let fresh = makeBookmark(for: url) {
                refreshed[index] = fresh
                didRefresh = true
            }
        }
        if didRefresh { defaults.set(refreshed, forKey: sessionKey) }
        return urls
    }

    /// Balance a `startAccessingSecurityScopedResource()` started by a resolve.
    /// Call once the document has been opened (its own bookmark keeps it alive).
    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Bookmark plumbing

    private func makeBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Non-fatal: session restore is a convenience, not a guarantee.
            NSLog("Ream: failed to bookmark document: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolve a bookmark to a URL, starting its security scope. Returns the URL
    /// and whether the bookmark was stale (so the caller can rewrite it). The
    /// caller owns the started scope and must `stopAccessing(_:)` it.
    private func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            _ = url.startAccessingSecurityScopedResource()
            return (url, isStale)
        } catch {
            return nil
        }
    }
}
