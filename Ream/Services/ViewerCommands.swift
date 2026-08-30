import Foundation

/// Registers the viewer's actions with the ⌘K command palette.
///
/// The palette (`CommandPaletteService`) is a global singleton, but viewer
/// actions target a specific window. We solve this the same way the menu bar
/// does: register commands that act on **whichever window is currently focused**.
/// Each `PaletteCommand` closure resolves the active ``DocumentWindowModel`` at
/// invocation time (via the weak reference handed in on the last window to
/// appear), so ⌘K always drives the front document.
///
/// Registration is idempotent — the palette replaces same-`id` commands — so
/// calling ``register(for:)`` on every window's `onAppear` simply repoints the
/// commands at the newly-focused window.
@MainActor
enum ViewerCommands {
    /// The window the palette commands currently act on. Weak so a closed window
    /// is released; commands no-op if it's gone.
    private static weak var activeModel: DocumentWindowModel?

    /// Point the palette commands at `model` — call this when its window becomes
    /// key so ⌘K always drives the focused document, not merely the last one to
    /// appear. Registration itself is idempotent (same ids replace).
    static func setActive(_ model: DocumentWindowModel) {
        activeModel = model
    }

    static func register(for model: DocumentWindowModel) {
        activeModel = model
        let palette = CommandPaletteService.shared

        palette.register([
            PaletteCommand(id: "view.invertContent", title: "Invert Page Content",
                           category: "View", keyboardShortcut: "⌘⇧I") {
                activeModel?.toggleDarkContent()
            },
            PaletteCommand(id: "view.toggleSidebar", title: "Toggle Sidebar",
                           category: "View", keyboardShortcut: "⌃⌘S") {
                activeModel?.toggleInspector()
            },
            PaletteCommand(id: "view.thumbnails", title: "Show Thumbnails",
                           category: "View") {
                activeModel?.showInspector(.thumbnails)
            },
            PaletteCommand(id: "view.outline", title: "Show Outline",
                           category: "View") {
                activeModel?.showInspector(.outline)
            },
            PaletteCommand(id: "find.search", title: "Find in Document",
                           category: "Find", keyboardShortcut: "⌘F") {
                activeModel?.focusSearch()
            },
            PaletteCommand(id: "find.next", title: "Find Next",
                           category: "Find", keyboardShortcut: "⌘G") {
                activeModel?.findNext()
            },
            PaletteCommand(id: "find.previous", title: "Find Previous",
                           category: "Find", keyboardShortcut: "⌘⇧G") {
                activeModel?.findPrevious()
            }
        ])

        // View-mode commands.
        for mode in ViewMode.allCases {
            palette.register(
                PaletteCommand(id: "view.mode.\(mode.rawValue)",
                               title: mode.title, category: "View Mode") {
                    activeModel?.setViewMode(mode)
                }
            )
        }

        // Zoom / fit commands routed through the coordinator.
        let zoomCommands: [(String, String, String?, PDFViewAction)] = [
            ("zoom.in", "Zoom In", "⌘+", .zoomIn),
            ("zoom.out", "Zoom Out", "⌘−", .zoomOut),
            ("zoom.actual", "Actual Size", "⌘0", .actualSize),
            ("zoom.fitPage", "Fit Page", "⌘1", .fitPage),
            ("zoom.fitWidth", "Fit Width", "⌘2", .fitWidth)
        ]
        for (id, title, shortcut, action) in zoomCommands {
            palette.register(
                PaletteCommand(id: id, title: title, category: "Zoom", keyboardShortcut: shortcut) {
                    activeModel?.coordinator.perform(action)
                }
            )
        }
    }
}
