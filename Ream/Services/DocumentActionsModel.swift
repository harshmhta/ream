import SwiftUI

/// Which metadata/security sheet a document window is currently showing.
///
/// A single `@Published` value drives `.sheet(item:)` in `PDFDocumentView`, so
/// only one of these is ever presented at a time.
enum DocumentSheet: String, Identifiable {
    case properties      // Document Properties (⌘I)
    case encrypt         // Encrypt…
    case stripConfirm    // Strip All Metadata confirmation
    case unlock          // Password prompt for a locked document

    var id: String { rawValue }
}

/// Per-window controller that lets app-level menu commands and ⌘K palette
/// entries drive the focused document's metadata/security sheets.
///
/// This mirrors the existing ``PDFViewCoordinator`` seam: `PDFDocumentView`
/// creates one, publishes it via `focusedSceneValue`, and `ReamCommands` reaches
/// the key window's instance through `@FocusedValue`.
@MainActor
final class DocumentActionsModel: ObservableObject {
    /// The sheet to present, or `nil` for none.
    @Published var activeSheet: DocumentSheet?

    /// A transient error to surface (e.g. an encryption/strip failure), shown as
    /// an alert by `PDFDocumentView`.
    @Published var errorMessage: String?

    func present(_ sheet: DocumentSheet) { activeSheet = sheet }
    func dismiss() { activeSheet = nil }
    func report(_ error: Error) { errorMessage = error.localizedDescription }
}
