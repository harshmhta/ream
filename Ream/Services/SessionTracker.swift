import Foundation
import AppKit

/// Tracks the set of currently-open documents so the app can restore the last
/// session (all tabs) on the next launch.
///
/// Windows register on appear and unregister on close; every change rewrites the
/// persisted session (a list of security-scoped bookmarks) via
/// ``RecentDocumentStore``. This complements macOS's own state restoration:
/// when the system restores windows we do nothing extra, and when it doesn't
/// (restoration disabled) ``AppDelegate`` reopens this list.
@MainActor
final class SessionTracker {
    static let shared = SessionTracker()

    /// Where the session is persisted. Injectable so tests can drive a tracker
    /// against a scratch `UserDefaults` suite instead of the real one.
    private let store: RecentDocumentStore

    init(store: RecentDocumentStore = .shared) {
        self.store = store
    }

    /// URLs of currently-open documents, insertion-ordered.
    private var openURLs: [URL] = []

    /// `persistenceKey` is the document's file-URL `absoluteString`.
    func register(_ document: PDFReferenceDocument) {
        guard let key = document.persistenceKey, let url = URL(string: key) else { return }
        if !openURLs.contains(url) {
            openURLs.append(url)
            persist()
        }
        // Keep the single most-recent pointer fresh too.
        store.remember(url)
    }

    func unregister(_ document: PDFReferenceDocument) {
        guard let key = document.persistenceKey, let url = URL(string: key) else { return }
        openURLs.removeAll { $0 == url }
        persist()
    }

    private func persist() {
        store.updateSession(openURLs: openURLs)
    }
}
