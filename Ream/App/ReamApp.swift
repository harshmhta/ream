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
            // Pass the file URL so the view can stamp a stable persistence key on
            // the document *before* the window model is created — the model reads
            // that key to restore per-document reading state on construction (and
            // remembers the document for reopen-on-relaunch).
            PDFDocumentView(document: file.document, fileURL: file.fileURL)
        }
        .commands {
            ReamCommands()
            AnnotationCommands()
        }
    }
}
