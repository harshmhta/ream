import SwiftUI

/// Exposes the key window's ``PDFViewCoordinator`` to the menu-bar commands.
///
/// SwiftUI `commands` live at the `App` level, outside any window's view tree.
/// `@FocusedValue` lets the menu reach the coordinator belonging to whichever
/// document window is currently focused, so ⌘+/⌘-/⌘0/⌘1 act on the right PDF.
private struct PDFCoordinatorKey: FocusedValueKey {
    typealias Value = PDFViewCoordinator
}

extension FocusedValues {
    var pdfCoordinator: PDFViewCoordinator? {
        get { self[PDFCoordinatorKey.self] }
        set { self[PDFCoordinatorKey.self] = newValue }
    }
}

/// Exposes the key window's ``PDFReferenceDocument`` so File-menu metadata and
/// security commands act on whichever document is focused.
private struct PDFDocumentKey: FocusedValueKey {
    typealias Value = PDFReferenceDocument
}

/// Exposes the key window's ``DocumentActionsModel`` so menu commands and the
/// ⌘K palette can open the Document Properties / Encrypt / Strip sheets on the
/// focused window.
private struct DocumentActionsKey: FocusedValueKey {
    typealias Value = DocumentActionsModel
}

extension FocusedValues {
    var pdfReferenceDocument: PDFReferenceDocument? {
        get { self[PDFDocumentKey.self] }
        set { self[PDFDocumentKey.self] = newValue }
    }

    var documentActions: DocumentActionsModel? {
        get { self[DocumentActionsKey.self] }
        set { self[DocumentActionsKey.self] = newValue }
    }
}
