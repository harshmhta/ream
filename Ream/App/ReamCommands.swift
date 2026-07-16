import SwiftUI

/// Menu-bar commands: View → zoom controls, and the ⌘K command palette toggle.
///
/// Zoom commands target the focused window's ``PDFViewCoordinator`` (via
/// `@FocusedValue`) and are disabled when no document window is key.
struct ReamCommands: Commands {
    @FocusedValue(\.pdfCoordinator) private var coordinator
    @FocusedValue(\.pdfReferenceDocument) private var document
    @FocusedValue(\.documentActions) private var actions
    @FocusedValue(\.pageOps) private var pageOps
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var palette = CommandPaletteService.shared

    var body: some Commands {
        // ⌘K — open the command palette. Placed in a text-editing-adjacent slot
        // so it is always reachable.
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") {
                palette.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()
        }

        // File menu: page operations, then metadata + security. Grouped after
        // the system Save/Import cluster (and the Info item so ⌘I lands
        // naturally). All target the focused window via @FocusedValue and disable
        // when no document is key.
        CommandGroup(after: .importExport) {
            Divider()

            Button("Manage Pages…") { pageOps?.showManagePages() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(pageOps == nil || document?.isLocked == true)

            Button("Merge PDFs…") { pageOps?.showMerge() }
                .disabled(pageOps == nil || document?.isLocked == true)

            Button("Split PDF…") { pageOps?.showSplit() }
                .disabled(pageOps == nil || document?.isLocked == true)

            Button("Insert Pages…") { pageOps?.showInsert() }
                .disabled(pageOps == nil || document?.isLocked == true)

            Divider()

            Button("Document Properties…") { actions?.present(.properties) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions == nil || document?.isLocked == true)

            Button("Encrypt…") { actions?.present(.encrypt) }
                .disabled(actions == nil || document?.isLocked == true)

            Button("Remove Password…") { removePassword() }
                .disabled(document?.canRemovePassword != true)

            Button("Strip All Metadata…") { actions?.present(.stripConfirm) }
                .disabled(actions == nil || document?.isLocked == true)

            Divider()
        }

        // View menu zoom controls with the shortcuts from the brief.
        CommandGroup(after: .sidebar) {
            Divider()

            Button("Zoom In") { coordinator?.perform(.zoomIn) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(coordinator == nil)

            Button("Zoom Out") { coordinator?.perform(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(coordinator == nil)

            Button("Actual Size") { coordinator?.perform(.actualSize) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(coordinator == nil)

            Button("Fit Page") { coordinator?.perform(.fitPage) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(coordinator == nil)

            Button("Fit Width") { coordinator?.perform(.fitWidth) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(coordinator == nil)
        }
    }

    /// Remove the password from the focused document, surfacing any error via
    /// the window's actions model.
    private func removePassword() {
        guard let document else { return }
        do {
            try document.removePassword(undoManager: undoManager)
        } catch {
            actions?.report(error)
        }
    }
}
