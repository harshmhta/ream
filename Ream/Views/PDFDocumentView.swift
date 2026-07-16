import SwiftUI
import PDFKit

/// The root view for a single open PDF document window.
///
/// Composes the PDFKit renderer with the ⌘K command palette overlay, and wires
/// the per-window ``PDFViewCoordinator`` into the environment so menu commands
/// (`ReamCommands`) can drive zoom for whichever window is key.
struct PDFDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    @StateObject private var coordinator = PDFViewCoordinator()
    @StateObject private var palette = CommandPaletteService.shared

    var body: some View {
        ZStack {
            if document.pdfDocument.pageCount > 0 {
                PDFKitView(document: document.pdfDocument, coordinator: coordinator)
                    .ignoresSafeArea()
            } else {
                emptyState
            }
        }
        .focusedSceneValue(\.pdfCoordinator, coordinator)
        .overlay {
            if palette.isPresented {
                CommandPaletteView()
                    .environmentObject(palette)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: palette.isPresented)
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
}
