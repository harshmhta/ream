import SwiftUI

/// Menu-bar commands: View → zoom controls, and the ⌘K command palette toggle.
///
/// Zoom commands target the focused window's ``PDFViewCoordinator`` (via
/// `@FocusedValue`) and are disabled when no document window is key.
struct ReamCommands: Commands {
    @FocusedValue(\.pdfCoordinator) private var coordinator
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
}
