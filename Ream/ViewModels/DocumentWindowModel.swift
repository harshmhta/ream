import SwiftUI
import PDFKit
import Combine

/// The per-window hub that owns everything a single open PDF needs: the render
/// coordinator, the search service, the inspector state, and dark-content mode.
///
/// Menus (`ReamCommands`) reach the focused window's instance through
/// `@FocusedValue(\.documentModel)` and drive it, so there is one object per
/// window that both the SwiftUI view and the menu bar talk to. Keeping this
/// state here (rather than scattered `@State` in the view) is what lets the menu
/// bar act on the right window.
@MainActor
final class DocumentWindowModel: ObservableObject {
    let document: PDFReferenceDocument
    let coordinator = PDFViewCoordinator()
    let search = SearchService()

    @Published var isInspectorVisible: Bool = true
    @Published var inspectorMode: InspectorMode = .thumbnails
    /// Set by the view; toggled true to pull keyboard focus into the search field.
    @Published var requestSearchFocus: Bool = false

    /// The document's outline tree, computed once when the document loads.
    @Published private(set) var outlineNodes: [OutlineNode]?

    private var saveWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    /// A shared empty model used only as a stand-in for menu items when no
    /// document window is focused (so `@ObservedObject` has something to bind to;
    /// the items are rendered disabled in that case). Never drives a real window.
    static let placeholder = DocumentWindowModel(document: PDFReferenceDocument())

    init(document: PDFReferenceDocument) {
        self.document = document
        self.outlineNodes = OutlineNode.tree(from: document.pdfDocument.outlineRoot,
                                             document: document.pdfDocument)
        search.attach(to: document.pdfDocument)

        // Forward the document's and coordinator's change notifications so that
        // menu commands observing this model (`@FocusedObject`) re-render when
        // dark-content or the view mode changes — keeping menu titles and the
        // active-mode checkmark in sync.
        document.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        coordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Route search focus changes to the coordinator's highlighter.
        search.onFocusResult = { [weak self] all, active in
            self?.coordinator.showSearchResults(all, active: active)
        }

        // Restore persisted per-document state (dark-content is applied here;
        // reading position is applied by the view once the PDFView exists).
        if let key = document.persistenceKey,
           let state = DocumentPreferencesStore.shared.readingState(for: key) {
            document.invertContent = state.invertContent
            if let mode = ViewMode(rawValue: state.viewModeRaw) {
                coordinator.perform(.setViewMode(mode))
            }
        }
    }

    /// The saved reading state to restore into the PDFView on first appearance.
    var initialReadingState: DocumentReadingState? {
        guard let key = document.persistenceKey else { return nil }
        return DocumentPreferencesStore.shared.readingState(for: key)
    }

    // MARK: - Inspector

    func toggleInspector() {
        isInspectorVisible.toggle()
    }

    func showInspector(_ mode: InspectorMode) {
        inspectorMode = mode
        isInspectorVisible = true
    }

    // MARK: - Search

    /// Reveal the search sidebar and move keyboard focus into its field (⌘F).
    func focusSearch() {
        showInspector(.search)
        requestSearchFocus = true
    }

    func findNext() {
        showInspector(.search)
        search.focusNext()
    }

    func findPrevious() {
        showInspector(.search)
        search.focusPrevious()
    }

    // MARK: - Dark content

    func toggleDarkContent() {
        document.invertContent.toggle()
        // Re-render every visible page through the new draw path. This reloads
        // the PDFView's document, which clears any search highlighting, so
        // re-push it afterward.
        coordinator.refreshRendering()
        search.reapplyHighlights()
        persistReadingStateNow()
    }

    // MARK: - View modes

    func setViewMode(_ mode: ViewMode) {
        coordinator.perform(.setViewMode(mode))
        persistReadingStateNow()
    }

    // MARK: - Reading-position persistence

    /// Persist the reading position, debounced (called on every scroll/zoom).
    func scheduleReadingStateSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistReadingStateNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Persist immediately (window closing, dark-content toggle, view-mode change).
    func persistReadingStateNow() {
        guard let key = document.persistenceKey,
              var state = coordinator.captureReadingState() else { return }
        state.invertContent = document.invertContent
        DocumentPreferencesStore.shared.setReadingState(state, for: key)
    }
}
