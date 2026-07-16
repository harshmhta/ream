import SwiftUI
import PDFKit

/// The root view for a single open PDF document window.
///
/// Composes the PDFKit renderer with the ⌘K command palette overlay, wires the
/// per-window ``PDFViewCoordinator`` and ``DocumentActionsModel`` into the
/// environment (so menu commands and the palette can drive this window), and
/// hosts the metadata/security sheets.
struct PDFDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    let fileURL: URL?
    @StateObject private var coordinator = PDFViewCoordinator()
    @StateObject private var actions = DocumentActionsModel()
    @StateObject private var palette = CommandPaletteService.shared
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ZStack {
            if document.isLocked {
                lockedState
            } else if document.pdfDocument.pageCount > 0 {
                PDFKitView(document: document.pdfDocument, coordinator: coordinator)
                    .ignoresSafeArea()
            } else {
                emptyState
            }
        }
        .focusedSceneValue(\.pdfCoordinator, coordinator)
        .focusedSceneValue(\.pdfReferenceDocument, document)
        .focusedSceneValue(\.documentActions, actions)
        .overlay {
            if palette.isPresented {
                CommandPaletteView()
                    .environmentObject(palette)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: palette.isPresented)
        .sheet(item: $actions.activeSheet, content: sheet)
        .alert("Operation Failed",
               isPresented: Binding(
                get: { actions.errorMessage != nil },
                set: { if !$0 { actions.errorMessage = nil } }
               ),
               presenting: actions.errorMessage) { _ in
            Button("OK", role: .cancel) { actions.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onAppear {
            registerPaletteCommands()
            promptForPasswordIfLocked()
        }
        .onDisappear(perform: unregisterPaletteCommands)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(for sheet: DocumentSheet) -> some View {
        switch sheet {
        case .properties:
            DocumentPropertiesView(document: document, fileURL: fileURL) {
                // Chain into the strip confirmation after Properties dismisses.
                actions.present(.stripConfirm)
            }
        case .encrypt:
            EncryptDocumentView(document: document)
        case .stripConfirm:
            StripMetadataView(document: document) { error in
                actions.report(error)
            }
        case .unlock:
            UnlockDocumentView(document: document)
        }
    }

    // MARK: - Locked / empty states

    private var lockedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.doc")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("This document is locked.")
                .font(.headline)
            Button("Enter Password…") { actions.present(.unlock) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("This document has no pages.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func promptForPasswordIfLocked() {
        if document.isLocked {
            actions.present(.unlock)
        }
    }

    // MARK: - ⌘K palette registration

    private func registerPaletteCommands() {
        palette.register([
            PaletteCommand(id: "doc.properties",
                           title: "Document Properties…",
                           category: "Document",
                           keyboardShortcut: "⌘I") { actions.present(.properties) },
            PaletteCommand(id: "doc.encrypt",
                           title: "Encrypt Document…",
                           category: "Security",
                           keyboardShortcut: nil) { actions.present(.encrypt) },
            PaletteCommand(id: "doc.removePassword",
                           title: "Remove Password…",
                           category: "Security",
                           keyboardShortcut: nil) { removePassword() },
            PaletteCommand(id: "doc.stripMetadata",
                           title: "Strip All Metadata…",
                           category: "Security",
                           keyboardShortcut: nil) { actions.present(.stripConfirm) },
        ])
    }

    private func unregisterPaletteCommands() {
        ["doc.properties", "doc.encrypt", "doc.removePassword", "doc.stripMetadata"]
            .forEach(palette.unregister(id:))
    }

    private func removePassword() {
        do {
            try document.removePassword(undoManager: undoManager)
        } catch {
            actions.report(error)
        }
    }
}
