import SwiftUI

/// The ⌘K command palette overlay.
///
/// v0.1 ships the palette shell: a search field and a results list bound to
/// ``CommandPaletteService``. It starts empty — downstream workers register
/// `PaletteCommand`s and they appear here automatically. Escape or clicking the
/// dimmed backdrop dismisses it.
struct CommandPaletteView: View {
    @EnvironmentObject private var palette: CommandPaletteService
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    private var results: [PaletteCommand] {
        palette.filtered(by: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — click to dismiss.
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { palette.isPresented = false }

            VStack(spacing: 0) {
                searchField
                Divider()
                resultsList
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(radius: 24, y: 8)
            .padding(.top, 96)
        }
        .onAppear { searchFocused = true }
        .onExitCommand { palette.isPresented = false }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search commands…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onSubmit {
                    if let first = results.first {
                        palette.run(first)
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultsList: some View {
        if palette.commands.isEmpty {
            emptyMessage("No commands available yet.")
        } else if results.isEmpty {
            emptyMessage("No commands match “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { command in
                        Button {
                            palette.run(command)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(command.title)
                                    if let category = command.category {
                                        Text(category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let shortcut = command.keyboardShortcut {
                                    Text(shortcut)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
    }
}
