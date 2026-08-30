import SwiftUI
import PDFKit

/// The root view for a single open PDF document window.
///
/// Composes the annotation toolbar, the PDFKit renderer (annotation-aware via
/// ``ReamPDFView``), the annotation inspector, the ⌘K command palette overlay,
/// the page-op sheets (Manage Pages / Merge / Split / Insert) with their
/// background-operation progress panel, the convert/export sheets (Compress /
/// Images → PDF / PDF → Images), and the metadata/security sheets. Wires the
/// per-window ``PDFViewCoordinator``, ``AnnotationController``,
/// ``PageOpsController``, ``ConversionCoordinator``, ``PDFReferenceDocument`` and
/// ``DocumentActionsModel`` into the environment so menu commands and the palette
/// can drive whichever window is focused. Locked (encrypted) documents show an
/// unlock prompt instead of the editor.
struct PDFDocumentView: View {
    @ObservedObject var document: PDFReferenceDocument
    let fileURL: URL?
    @StateObject private var coordinator = PDFViewCoordinator()
    @StateObject private var actions = DocumentActionsModel()
    @StateObject private var conversion = ConversionCoordinator()
    @StateObject private var palette = CommandPaletteService.shared
    @StateObject private var annotations: AnnotationController
    @StateObject private var pageOps: PageOpsController
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
        _pageOps = StateObject(wrappedValue: PageOpsController(document: document))
    }

    var body: some View {
        // The four `.sheet(item:)` bindings (annotation editing, page ops,
        // convert/export, metadata/security) are attached to *different* views —
        // the annotation editor to `canvas`, the page-op sheet to `editorRoot`,
        // the convert/export sheet to `documentRoot`, and the metadata/security
        // sheet here — so no view hosts more than one sheet.
        documentRoot
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
    }

    /// ``editorRoot`` plus the convert/export sheet. This sits on its own level so
    /// the conversion sheet does not share a host view with the page-op sheet.
    private var documentRoot: some View {
        editorRoot
            .sheet(item: $conversion.activeSheet, content: conversionSheet)
    }

    private var editorRoot: some View {
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
        .focusedSceneValue(\.conversionCoordinator, conversion)
        .focusedSceneValue(\.pageOps, pageOps)
        .animation(.easeInOut(duration: 0.15), value: showInspector)
        .overlay { paletteOverlay }
        .overlay { progressOverlay }
        .animation(.easeInOut(duration: 0.12), value: palette.isPresented)
        .sheet(item: $pageOps.activeSheet, content: pageOpsSheet)
        .alert("Operation Failed",
               isPresented: Binding(get: { pageOps.errorMessage != nil },
                                    set: { if !$0 { pageOps.errorMessage = nil } })) {
            Button("OK", role: .cancel) { pageOps.errorMessage = nil }
        } message: {
            Text(pageOps.errorMessage ?? "")
        }
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            conversion.document = document
            conversion.documentTitle = fileURL?.lastPathComponent ?? "Document"
            ConversionCoordinator.active = conversion
            pageOps.coordinator = coordinator
            pageOps.undoManager = undoManager
            pageOps.registerPaletteCommands()
            registerPaletteCommands()
            ConversionCommands.registerIfNeeded()
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showInspector)
            promptForPasswordIfLocked()
        }
        // Keep the page-ops controller's undo manager current — the environment
        // value can arrive/refresh after first appearance.
        .onChange(of: undoManager) { _, newValue in
            pageOps.undoManager = newValue
        }
        // Re-layout the on-screen view after in-place page mutations.
        .onReceive(NotificationCenter.default.publisher(for: .reamPagesDidChange)) { note in
            if note.object as? PDFReferenceDocument === document {
                coordinator.perform(.reload)
            }
        }
        // Re-target the annotation + conversion palette commands at this document
        // whenever *this* window takes key, so ⌘K acts on the focused document
        // (not whichever opened last).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let keyed = note.object as? NSWindow, keyed === hostWindow else { return }
            ConversionCoordinator.active = conversion
            AnnotationCommandRegistrar.setActive(annotations, showInspector: $showInspector)
        }
        .onDisappear {
            pageOps.unregisterPaletteCommands()
            unregisterPaletteCommands()
        }
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
    private func pageOpsSheet(_ sheet: PageOpsController.Sheet) -> some View {
        switch sheet {
        case .managePages:
            ManagePagesView(document: document, controller: pageOps)
        case .merge:
            MergePDFsView(controller: pageOps)
        case .split:
            SplitPDFView(controller: pageOps)
        case .insert:
            InsertPagesView(controller: pageOps)
        }
    }

    @ViewBuilder
    private func conversionSheet(_ sheet: ConversionCoordinator.ActiveSheet) -> some View {
        switch sheet {
        case .compress:
            CompressSheet(coordinator: conversion)
        case .imagesToPDF:
            ImagesToPDFSheet(coordinator: conversion)
        case .pdfToImages:
            PDFToImagesSheet(coordinator: conversion)
        }
    }

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

    // MARK: - Overlays

    @ViewBuilder
    private var paletteOverlay: some View {
        if palette.isPresented {
            CommandPaletteView()
                .environmentObject(palette)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var progressOverlay: some View {
        if let progress = pageOps.progress {
            OperationProgressView(progress: progress) {
                pageOps.cancelCurrentOperation()
            }
            .transition(.opacity)
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
