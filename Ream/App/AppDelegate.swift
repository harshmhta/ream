import AppKit

/// Application delegate for lifecycle hooks that SwiftUI does not expose.
///
/// Its main job in v0.1 is "reopen last document on relaunch": if macOS did not
/// restore any document windows (e.g. the user has window restoration disabled),
/// we open the most recently viewed PDF ourselves.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Give the system a moment to perform its own window restoration before
        // we decide whether we need to reopen the last document manually.
        DispatchQueue.main.async { [weak self] in
            self?.reopenLastDocumentIfNeeded()
        }
    }

    /// Do not create a blank untitled document on launch — Ream is a viewer,
    /// so an empty window would be meaningless. The open panel / recents handle
    /// the "no document" case.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    private func reopenLastDocumentIfNeeded() {
        let controller = NSDocumentController.shared
        // If a document was already restored or opened, do nothing.
        guard controller.documents.isEmpty else { return }

        guard let url = RecentDocumentStore.shared.lastDocumentURL() else { return }
        controller.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}
