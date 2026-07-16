import SwiftUI
import PDFKit

/// The root view for a single open PDF document window.
///
/// Composes the annotation toolbar, the PDFKit renderer (annotation-aware via
/// ``ReamPDFView``), the annotation inspector, and the ⌘K command palette
/// overlay. Wires the per-window ``PDFViewCoordinator``, ``AnnotationController``,
/// ``PDFReferenceDocument`` and ``DocumentActionsModel`` into the environment so
/// menu commands and the palette can drive whichever window is focused, and
/// hosts the metadata/security sheets. Locked (encrypted) documents show an
/// unlock prompt instead of the editor.
struct PDFDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    let fileURL: URL?
    @StateObject private var coordinator = PDFViewCoordinator()
    @StateObject private var actions = DocumentActionsModel()
    @StateObject private var palette = CommandPaletteService.shared
    @StateObject private var annotations: AnnotationController
    @Environment(\.undoManager) private var undoManager

    @State private var showInspector = false
    @State private var showStampPicker = false
    /// This view's host window, captured so we only re-target the palette when
    /// *our* window (not some other document's) becomes key.
    @State private var hostWindow: NSWindow?

    init(document: PDFReferenceDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        _annotations = StateObject(wrappedValue: AnnotationController(document: document))
    }

    var body: some View {
        Group {
            if document.isLocked {
                lockedState
            } else {
                editorLayout
            }
        }
        .focusedSceneValue(\.pdfCoordinator, coordinator)
        .focusedSceneValue(\.pdfReferenceDocument, document)
        .focusedSceneValue(\.documentActions, actions)
        .focusedSceneValue(\.annotationController, annotations)
        .animation(.easeInOut(duration: 0.15), value: showInspector)
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
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            registerPaletteCommands()
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showInspector)
            promptForPasswordIfLocked()
        }
        // Re-target the annotation palette commands at this document whenever
        // *this* window takes key, so ⌘K acts on the focused document (not
        // whichever opened last).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let keyed = note.object as? NSWindow, keyed === hostWindow else { return }
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showInspector)
        }
        .onDisappear(perform: unregisterPaletteCommands)
    }

    /// Toolbar + canvas + optional inspector, shown when the document is unlocked.
    private var editorLayout: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(controller: annotations,
                              showStampPicker: $showStampPicker,
                              showInspector: $showInspector)
                .popover(isPresented: $showStampPicker, arrowEdge: .top) {
                    StampPickerView(controller: annotations, isPresented: $showStampPicker)
                }
            Divider()
            HStack(spacing: 0) {
                canvas
                if showInspector {
                    Divider()
                    AnnotationInspector(controller: annotations)
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private var canvas: some View {
        ZStack {
            if document.pdfDocument.pageCount > 0 {
                PDFKitView(document: document.pdfDocument,
                           coordinator: coordinator,
                           annotationController: annotations)
                    .ignoresSafeArea()
            } else {
                emptyState
            }
        }
        // Present the note / free-text editor as a sheet anchored to the window
        // when an annotation asks to be edited.
        .sheet(item: Binding(
            get: { annotations.editingAnnotation.map { EditingBox(annotation: $0) } },
            set: { annotations.editingAnnotation = $0?.annotation })
        ) { box in
            NoteEditorView(controller: annotations, annotation: box.annotation)
        }
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

/// Identifiable wrapper so a `PDFAnnotation` can drive `.sheet(item:)`.
private struct EditingBox: Identifiable {
    let annotation: PDFAnnotation
    var id: String { annotation.reamID }
}

/// Bridges to the host `NSWindow` so the view can tell whether a
/// `didBecomeKeyNotification` refers to its own window.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
