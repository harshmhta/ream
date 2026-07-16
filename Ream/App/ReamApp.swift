import SwiftUI
import UniformTypeIdentifiers

/// The Ream application entry point.
///
/// Ream is a document-based SwiftUI app. `DocumentGroup` gives us tabs,
/// multiple windows, Finder open, drag-onto-dock, and native state restoration
/// (reopen-on-relaunch) for free. Each open PDF is backed by a
/// ``PDFReferenceDocument``.
@main
struct ReamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(viewing: PDFReferenceDocument.self) { file in
            PDFDocumentView(document: file.document)
                .onAppear {
                    // Remember this document so we can reopen it if the system
                    // does not restore windows on the next launch.
                    if let url = file.fileURL {
                        RecentDocumentStore.shared.remember(url)
                    }
                }
        }
        .commands {
            ReamCommands()
        }
    }
}
