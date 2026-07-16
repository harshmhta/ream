import SwiftUI
import AppKit

/// Menu-bar commands for the viewer: the ⌘K palette, Find, View modes, zoom,
/// dark-content inversion, sidebar, and presentation.
///
/// Everything that acts on a document targets the focused window's
/// ``DocumentWindowModel`` via `@FocusedValue`, so the commands always drive
/// whichever window is key and disable themselves when no document is open.
struct ReamCommands: Commands {
    // Viewer (tabs / search / view modes / dark-content) targets the focused
    // window's DocumentWindowModel; metadata + security target its
    // PDFReferenceDocument / DocumentActionsModel. All via @FocusedValue.
    @FocusedValue(\.documentModel) private var model
    @FocusedValue(\.pdfReferenceDocument) private var document
    @FocusedValue(\.documentActions) private var actions
    @Environment(\.undoManager) private var undoManager
    @ObservedObject private var palette = CommandPaletteService.shared

    var body: some Commands {
        // ⌘K — command palette.
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { palette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
        }

        // File menu: metadata + security. Grouped after the system Info item so
        // ⌘I lands naturally. All target the focused window via @FocusedValue and
        // disable when no document is key.
        CommandGroup(after: .importExport) {
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

        // New tab via Open, and tab cycling. ⌘W (close tab) and the native tab
        // bar come from `DocumentGroup` + `allowsAutomaticWindowTabbing`.
        CommandGroup(after: .newItem) {
            Button("Open in New Tab…") { NSDocumentController.shared.openDocument(nil) }
                .keyboardShortcut("t", modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Show Next Tab") { NSApp.keyWindow?.selectNextTab(nil) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { NSApp.keyWindow?.selectPreviousTab(nil) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }

        // Find menu (Edit-adjacent).
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model == nil)
            Button("Find Previous") { model?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        // View menu: sidebar, dark-content, view modes, page nav, presentation.
        //
        // Each logical section is wrapped in a `Group` so the `CommandGroup`
        // sees only a handful of direct children. `@CommandsBuilder` (like
        // `ViewBuilder`) supports at most 10 direct statements; a flat list of
        // ~19 buttons here silently drops everything past the first 10, which is
        // exactly the bug that showed up as "only the zoom items appear".
        CommandGroup(after: .sidebar) {
            // These two items have *dynamic* titles (Hide/Show, Invert/Restore),
            // so they live in an `@ObservedObject` helper view — that is what
            // makes their titles refresh live when the model publishes a change.
            DarkAndSidebarItems(model: model)

            Divider()

            // View modes — the active one gets a checkmark; also observed so the
            // checkmark moves when the mode changes.
            ViewModeItems(model: model)

            Divider()

            Group {
                Button("Go to Next Page") { model?.coordinator.perform(.nextPage) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(model == nil)
                Button("Go to Previous Page") { model?.coordinator.perform(.previousPage) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(model == nil)

                Button("Toggle Presentation Mode") { model?.coordinator.perform(.togglePresentation) }
                    .keyboardShortcut("p", modifiers: [.command, .shift, .option])
                    .disabled(model == nil)
            }

            Divider()

            Group {
                Button("Zoom In") { model?.coordinator.perform(.zoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(model == nil)
                Button("Zoom Out") { model?.coordinator.perform(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(model == nil)
                Button("Actual Size") { model?.coordinator.perform(.actualSize) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model == nil)
                Button("Fit Page") { model?.coordinator.perform(.fitPage) }
                    .keyboardShortcut("1", modifiers: .command)
                    .disabled(model == nil)
                Button("Fit Width") { model?.coordinator.perform(.fitWidth) }
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(model == nil)
            }
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

/// Sidebar-toggle + dark-content items with live titles.
///
/// Rendered as an `@ObservedObject` view (not inline in the `Commands` struct)
/// so that when the focused model publishes a change — dark-content toggled,
/// sidebar shown/hidden — the "Hide/Show Sidebar" and "Invert/Restore Page
/// Content" titles update immediately. A plain `@FocusedValue` read inside a
/// `Commands` body does not re-evaluate on the model's own changes.
///
/// When no document is focused (`model == nil`) the items still render, but
/// disabled — matching the zoom/find items so the View menu's structure stays
/// stable rather than having items appear and disappear with focus.
private struct DarkAndSidebarItems: View {
    @ObservedObject var model: DocumentWindowModel
    private let hasModel: Bool

    init(model: DocumentWindowModel?) {
        // A placeholder model keeps @ObservedObject happy when nothing is
        // focused; `hasModel` drives the disabled state and title fallbacks.
        self.model = model ?? DocumentWindowModel.placeholder
        self.hasModel = model != nil
    }

    var body: some View {
        Button(model.isInspectorVisible ? "Hide Sidebar" : "Show Sidebar") {
            model.toggleInspector()
        }
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(!hasModel)

        Button(model.document.invertContent ? "Restore Page Content" : "Invert Page Content") {
            model.toggleDarkContent()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!hasModel)
    }
}

/// The four view-mode items; the active one is prefixed with a checkmark. Also
/// observed so the checkmark tracks the current mode. Renders disabled (not
/// absent) when no document is focused, for a stable menu structure.
private struct ViewModeItems: View {
    @ObservedObject var model: DocumentWindowModel
    private let hasModel: Bool

    init(model: DocumentWindowModel?) {
        self.model = model ?? DocumentWindowModel.placeholder
        self.hasModel = model != nil
    }

    var body: some View {
        item(.singlePage)
        item(.continuous)
        item(.twoUp)
        item(.book)
    }

    private func item(_ mode: ViewMode) -> some View {
        let active = hasModel && model.coordinator.viewMode == mode
        return Button((active ? "✓ " : "    ") + mode.title) {
            model.setViewMode(mode)
        }
        .disabled(!hasModel)
    }
}
