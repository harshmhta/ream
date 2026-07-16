import SwiftUI
import PDFKit

/// The root view for a single open PDF document window.
///
/// Composes every Phase-2 viewer surface into one window:
/// - the annotation toolbar (top) and annotation inspector (right),
/// - the left inspector (Thumbnails / Outline / Search) beside the PDFKit
///   renderer (annotation-aware + de-hyphenating via ``ReamPDFView``),
/// - dark-content mode, view modes, and the ⌘K command palette overlay,
/// - the metadata / security sheets.
///
/// The per-window ``DocumentWindowModel`` (which owns the ``PDFViewCoordinator``,
/// search, and inspector state), the ``AnnotationController``, the
/// ``PDFReferenceDocument`` and the ``DocumentActionsModel`` are published into
/// the focus environment so menu commands and the palette drive whichever window
/// is focused. Locked (encrypted) documents show an unlock prompt instead.
struct PDFDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    let fileURL: URL?
    @StateObject private var model: DocumentWindowModel
    @StateObject private var annotations: AnnotationController
    @StateObject private var actions = DocumentActionsModel()
    @StateObject private var palette = CommandPaletteService.shared
    @Environment(\.undoManager) private var undoManager

    @FocusState private var searchFieldFocused: Bool
    @State private var showAnnotationInspector = false
    @State private var showStampPicker = false
    /// This view's host window, so we only re-target the palettes when *our*
    /// window (not another document's) becomes key.
    @State private var hostWindow: NSWindow?

    init(document: PDFReferenceDocument, fileURL: URL? = nil) {
        self.document = document
        self.fileURL = fileURL
        // Stamp the persistence key before the window model is built so it can
        // restore this document's saved reading state during construction (and
        // remember the document for reopen-on-relaunch).
        if let fileURL, document.persistenceKey == nil {
            document.persistenceKey = fileURL.absoluteString
            RecentDocumentStore.shared.remember(fileURL)
        }
        _model = StateObject(wrappedValue: DocumentWindowModel(document: document))
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
        .focusedSceneValue(\.documentModel, model)
        .focusedSceneValue(\.pdfCoordinator, model.coordinator)
        .focusedSceneValue(\.pdfReferenceDocument, document)
        .focusedSceneValue(\.documentActions, actions)
        .focusedSceneValue(\.annotationController, annotations)
        .overlay {
            if palette.isPresented {
                CommandPaletteView()
                    .environmentObject(palette)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: palette.isPresented)
        .animation(.easeInOut(duration: 0.15), value: showAnnotationInspector)
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
            ViewerCommands.register(for: model)
            registerDocumentPaletteCommands()
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showAnnotationInspector)
            SessionTracker.shared.register(document)
            promptForPasswordIfLocked()
        }
        // Re-target the per-window palettes at this document whenever *this*
        // window takes key, so ⌘K and the menus act on the focused document.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let keyed = note.object as? NSWindow, keyed === hostWindow else { return }
            ViewerCommands.setActive(model)
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showAnnotationInspector)
        }
        .onChange(of: model.requestSearchFocus) { _, wants in
            if wants {
                searchFieldFocused = true
                model.requestSearchFocus = false
            }
        }
        .onDisappear {
            model.persistReadingStateNow()
            SessionTracker.shared.unregister(document)
            unregisterDocumentPaletteCommands()
        }
    }

    // MARK: - Editor layout

    /// Annotation toolbar + [left inspector | canvas] + optional annotation
    /// inspector, shown when the document is unlocked.
    private var editorLayout: some View {
        VStack(spacing: 0) {
            AnnotationToolbar(controller: annotations,
                              showStampPicker: $showStampPicker,
                              showInspector: $showAnnotationInspector)
                .popover(isPresented: $showStampPicker, arrowEdge: .top) {
                    StampPickerView(controller: annotations, isPresented: $showStampPicker)
                }
            Divider()
            HStack(spacing: 0) {
                HSplitView {
                    if model.isInspectorVisible {
                        InspectorSidebar(
                            mode: $model.inspectorMode,
                            pdfView: model.coordinator.pdfView,
                            outlineNodes: model.outlineNodes,
                            search: model.search,
                            searchFieldFocus: $searchFieldFocused,
                            onJumpToPage: { model.coordinator.perform(.goToPage($0)) },
                            onSelectResult: { model.search.focus(result: $0) }
                        )
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 420)
                    }
                    canvas
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
                if showAnnotationInspector {
                    Divider()
                    AnnotationInspector(controller: annotations)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .toolbar { toolbarContent }
    }

    private var canvas: some View {
        ZStack {
            if document.pdfDocument.pageCount > 0 {
                PDFKitView(
                    document: document.pdfDocument,
                    coordinator: model.coordinator,
                    annotationController: annotations,
                    initialState: model.initialReadingState,
                    onReadingStateChange: { model.scheduleReadingStateSave() }
                )
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.toggleInspector()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle Sidebar")
        }
        ToolbarItem {
            Button {
                model.toggleDarkContent()
            } label: {
                Image(systemName: document.invertContent ? "circle.lefthalf.filled.inverse" : "circle.lefthalf.filled")
            }
            .help("Invert Page Content (⌘⇧I)")
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

    // MARK: - ⌘K palette registration (metadata + security)

    private func registerDocumentPaletteCommands() {
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

    private func unregisterDocumentPaletteCommands() {
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
