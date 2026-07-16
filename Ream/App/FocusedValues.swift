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
