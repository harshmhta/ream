import Foundation

/// Remembers the most recently opened document so the app can reopen it on the
/// next launch if the system did not restore windows.
///
/// Under the App Sandbox we cannot simply stash a path and reopen it later —
/// the sandbox would deny access. We persist a **security-scoped bookmark** and
/// resolve it on relaunch to regain permission to the file the user chose.
final class RecentDocumentStore {
    static let shared = RecentDocumentStore()

    private let defaults: UserDefaults
    private let bookmarkKey = "com.ream.app.lastDocumentBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persist a security-scoped bookmark to `url` as the last-opened document.
    func remember(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: bookmarkKey)
        } catch {
            // Non-fatal: reopen-last is a convenience, not a guarantee.
            NSLog("Ream: failed to bookmark last document: \(error.localizedDescription)")
        }
    }

    /// Resolve and return the last-opened document URL, if one exists and is
    /// still reachable. The caller is responsible for opening it; the returned
    /// URL already had its security scope started for immediate use.
    func lastDocumentURL() -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            _ = url.startAccessingSecurityScopedResource()
            if isStale {
                // Refresh the bookmark so it keeps resolving in the future.
                remember(url)
            }
            return url
        } catch {
            return nil
        }
    }
}
