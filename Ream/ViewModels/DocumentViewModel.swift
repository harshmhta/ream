import Foundation
import PDFKit

/// Derived, view-facing state for a single open document.
///
/// Keeps display logic out of the SwiftUI view. Thin in v0.1 (page count and a
/// display title); Phase 2 view models (sidebar, search, annotation list) will
/// sit alongside this one.
@MainActor
final class DocumentViewModel: ObservableObject {
    private let document: PDFReferenceDocument

    init(document: PDFReferenceDocument) {
        self.document = document
    }

    /// Number of pages in the document.
    var pageCount: Int {
        document.pdfDocument.pageCount
    }

    /// Whether there is any content to display.
    var hasPages: Bool {
        pageCount > 0
    }

    /// A best-effort display title from the PDF's metadata, falling back to the
    /// file name the window already shows.
    var displayTitle: String? {
        document.pdfDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
    }
}
