import AppKit

/// Application delegate for lifecycle hooks that SwiftUI does not expose.
///
/// Its main job in v0.1 is "reopen last session on relaunch": if macOS did not
/// restore any document windows (e.g. the user has window restoration disabled),
/// we reopen every document that was open when the app last quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Allow multiple PDFs to live as tabs in one window. Whether documents
        // open as tabs or separate windows then follows the macOS "Prefer tabs"
        // system setting — the same native behaviour as Preview.
        NSWindow.allowsAutomaticWindowTabbing = true

        // SwiftUI's `DocumentGroup` performs its own state restoration of the
        // last open documents. We only reopen manually as a *fallback* for when
        // the system restored nothing (e.g. "Close windows when quitting an app"
        // is on). Restoration is asynchronous, so we wait briefly and then only
        // open session URLs that are not already open — otherwise we would
        // duplicate every window the system just restored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.reopenLastSessionIfNeeded()
        }
    }

    /// Do not create a blank untitled document on launch — Ream is a viewer,
    /// so an empty window would be meaningless. The open panel / recents handle
    /// the "no document" case.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    private func reopenLastSessionIfNeeded() {
        let controller = NSDocumentController.shared

        // Prefer the full last session (all tabs); fall back to the single most
        // recent document for backwards compatibility.
        let sessionURLs = RecentDocumentStore.shared.sessionURLs()
        let urls = sessionURLs.isEmpty
            ? [RecentDocumentStore.shared.lastDocumentURL()].compactMap { $0 }
            : sessionURLs
        guard !urls.isEmpty else { return }

        // Documents the system already restored / the user already opened. See
        // ``SessionRestore`` for why the skipped ones still need releasing.
        let openPaths = Set(controller.documents.compactMap {
            $0.fileURL.map(SessionRestore.canonicalPath)
        })
        let plan = SessionRestore.plan(sessionURLs: urls, alreadyOpen: openPaths)

        // Already on screen (or a duplicate): we never open it, so nothing else
        // will balance the security scope the bookmark resolve started.
        for url in plan.release {
            RecentDocumentStore.shared.stopAccessing(url)
        }

        for url in plan.open {
            controller.openDocument(withContentsOf: url, display: true) { _, _, _ in
                // The document now holds its own access; release the scope the
                // bookmark resolve started so we don't leak one per restored tab.
                RecentDocumentStore.shared.stopAccessing(url)
            }
        }
    }
}
