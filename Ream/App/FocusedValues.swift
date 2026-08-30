import SwiftUI

/// Exposes the key window's ``DocumentWindowModel`` to the menu-bar commands.
///
/// SwiftUI `commands` live at the `App` level, outside any window's view tree.
/// `@FocusedValue` lets the menu reach the model belonging to whichever document
/// window is currently focused, so View-menu items and Find act on the right PDF.
/// `ReamCommands` then re-observes that model via a nested `@ObservedObject` view
/// so menu titles and checkmarks stay in sync with its published state.
private struct DocumentModelKey: FocusedValueKey {
    typealias Value = DocumentWindowModel
}

private struct PDFCoordinatorKey: FocusedValueKey {
    typealias Value = PDFViewCoordinator
}

/// Exposes the key window's ``AnnotationController`` to the Annotations menu
/// commands (Import/Export XFDF, Flatten, markup shortcuts).
private struct AnnotationControllerKey: FocusedValueKey {
    typealias Value = AnnotationController
}

/// Exposes the key window's ``PageOpsController`` so the File-menu page-ops
/// commands act on whichever document window is focused.
private struct PageOpsControllerKey: FocusedValueKey {
    typealias Value = PageOpsController
}

extension FocusedValues {
    var documentModel: DocumentWindowModel? {
        get { self[DocumentModelKey.self] }
        set { self[DocumentModelKey.self] = newValue }
    }

    var pdfCoordinator: PDFViewCoordinator? {
        get { self[PDFCoordinatorKey.self] }
        set { self[PDFCoordinatorKey.self] = newValue }
    }

    var annotationController: AnnotationController? {
        get { self[AnnotationControllerKey.self] }
        set { self[AnnotationControllerKey.self] = newValue }
    }

    /// The key window's ``PageOpsController``, exposed so the File-menu page-ops
    /// commands act on whichever document window is focused.
    var pageOps: PageOpsController? {
        get { self[PageOpsControllerKey.self] }
        set { self[PageOpsControllerKey.self] = newValue }
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
