import SwiftUI
import Combine

/// A single command that can be invoked from the ⌘K command palette.
///
/// Downstream Phase 2 workers (annotations, page ops, compress, …) register
/// their actions here so every feature is reachable from one keyboard-driven
/// surface, per the scope's "command palette (⌘K) for every action" goal.
struct PaletteCommand: Identifiable {
    /// Stable, unique identifier (e.g. `"page.rotateClockwise"`). Used for
    /// de-duplication and future persistence of recents/favorites.
    let id: String

    /// User-facing title shown in the palette (e.g. "Rotate Page Clockwise").
    let title: String

    /// Optional grouping label (e.g. "Pages", "Annotate") for sectioning.
    let category: String?

    /// Optional human-readable shortcut hint (e.g. "⌘⇧R"). Display only —
    /// the actual key binding is owned by the menu/command that triggers it.
    let keyboardShortcut: String?

    /// The work performed when the user selects this command.
    let action: () -> Void

    init(
        id: String,
        title: String,
        category: String? = nil,
        keyboardShortcut: String? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.keyboardShortcut = keyboardShortcut
        self.action = action
    }
}

/// The registry + presentation state for the ⌘K command palette.
///
/// This is the seam the whole app builds against. In v0.1 it starts empty and
/// simply shows "No commands available yet." Register commands like so:
///
/// ```swift
/// CommandPaletteService.shared.register(
///     PaletteCommand(id: "page.rotateCW", title: "Rotate Page Clockwise") {
///         // perform rotation
///     }
/// )
/// ```
@MainActor
final class CommandPaletteService: ObservableObject {
    static let shared = CommandPaletteService()

    /// All registered commands, in registration order.
    @Published private(set) var commands: [PaletteCommand] = []

    /// Whether the palette overlay is currently visible.
    @Published var isPresented: Bool = false

    private init() {}

    /// Register a command. Re-registering the same `id` replaces the prior one,
    /// so it is safe for views to register on appear without duplicating.
    func register(_ command: PaletteCommand) {
        if let index = commands.firstIndex(where: { $0.id == command.id }) {
            commands[index] = command
        } else {
            commands.append(command)
        }
    }

    /// Register many commands at once.
    func register(_ newCommands: [PaletteCommand]) {
        newCommands.forEach(register)
    }

    /// Remove a previously registered command by id (e.g. when a document that
    /// owns the command closes).
    func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Toggle palette visibility — bound to ⌘K.
    func toggle() {
        isPresented.toggle()
    }

    /// Case-insensitive fuzzy-ish filter over titles and categories.
    func filtered(by query: String) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commands }
        return commands.filter { command in
            command.title.localizedCaseInsensitiveContains(trimmed)
                || (command.category?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    /// Run a command and dismiss the palette.
    func run(_ command: PaletteCommand) {
        isPresented = false
        command.action()
    }
}
