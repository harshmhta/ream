import Foundation
import PDFKit
import Combine
import ReamCore

/// One search hit, tying a ReamCore text match to the PDF page it lives on.
struct SearchResult: Identifiable {
    let id = UUID()
    /// Zero-based page index.
    let pageIndex: Int
    /// One-line preview snippet (from ReamCore).
    let preview: String
    /// Range of the hit within `preview`, for emphasis in the list.
    let previewMatchRange: NSRange
    /// UTF-16 range of the hit within the page's text — used to rebuild the
    /// `PDFSelection` for highlight/jump.
    let pageRange: NSRange
}

/// Full-text search across an open PDF, with instant-as-you-type results and
/// whole-word / case-sensitive / regex toggles.
///
/// The actual matching lives in ``ReamCore/PlainTextSearch`` (pure, unit-tested);
/// this service is the app-side glue: it walks the document's pages off the main
/// actor, feeds each page's text to the matcher, and republishes results plus a
/// current-hit cursor for ⌘G / ⌘⇧G navigation. Searches are debounced and
/// cancellable so typing in a 500-page document stays responsive.
@MainActor
final class SearchService: ObservableObject {
    @Published var query: String = ""
    @Published var options = TextSearchOptions()
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var isSearching = false
    /// Index into `results` of the currently-focused hit, or `nil` if none.
    @Published private(set) var currentIndex: Int?

    private weak var document: PDFKit.PDFDocument?
    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Called when the active result changes so the coordinator can highlight
    /// and scroll. Injected by the view.
    var onFocusResult: ((_ all: [PDFSelection], _ active: PDFSelection?) -> Void)?

    init() {
        // Re-run search when the query or any toggle changes, debounced so we
        // don't thrash on every keystroke.
        Publishers.CombineLatest($query, $options)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] query, options in
                self?.runSearch(query: query, options: options)
            }
            .store(in: &cancellables)
    }

    /// Cached page text, extracted once per document. Page `.string` extraction
    /// walks the content stream and is expensive; the text does not change while
    /// a document is open (v0.1 is read-only), so we extract lazily on the first
    /// search and reuse it for every subsequent keystroke instead of re-walking
    /// all pages each time.
    private var pageTextCache: [(index: Int, text: String)]?

    func attach(to document: PDFKit.PDFDocument) {
        self.document = document
        pageTextCache = nil
    }

    /// Extract (and cache) the non-empty text of every page, on the main actor
    /// (PDFKit is not thread-safe).
    private func pageTexts(for document: PDFKit.PDFDocument) -> [(index: Int, text: String)] {
        if let cache = pageTextCache { return cache }
        let texts: [(index: Int, text: String)] = (0..<document.pageCount).compactMap { i in
            guard let page = document.page(at: i), let text = page.string, !text.isEmpty else { return nil }
            return (i, text)
        }
        pageTextCache = texts
        return texts
    }

    /// The number of hits found (convenience for the UI).
    var resultCount: Int { results.count }

    // MARK: - Searching

    private func runSearch(query: String, options: TextSearchOptions) {
        searchTask?.cancel()

        let trimmed = options.regex ? query : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let document else {
            results = []
            currentIndex = nil
            isSearching = false
            onFocusResult?([], nil)
            return
        }

        // Reuse the cached page text (extracted once per document) and match
        // off-actor. Matching is pure String work, safe off the main actor.
        let texts = pageTexts(for: document)

        isSearching = true
        searchTask = Task { [weak self] in
            let found = await Self.match(pageTexts: texts, query: query, options: options)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.results = found
                self.isSearching = false
                if found.isEmpty {
                    self.currentIndex = nil
                    self.onFocusResult?([], nil)
                } else {
                    self.focus(index: 0)
                }
            }
        }
    }

    /// Pure matching step — runs off the main actor.
    private nonisolated static func match(
        pageTexts: [(index: Int, text: String)],
        query: String,
        options: TextSearchOptions
    ) async -> [SearchResult] {
        var out: [SearchResult] = []
        for page in pageTexts {
            if Task.isCancelled { return out }
            let matches = PlainTextSearch.matches(in: page.text, query: query, options: options)
            for m in matches {
                out.append(SearchResult(pageIndex: page.index,
                                        preview: m.preview,
                                        previewMatchRange: m.previewMatchRange,
                                        pageRange: m.range))
            }
        }
        return out
    }

    // MARK: - Navigation

    /// Focus a specific result: rebuild selections and notify the view.
    func focus(index: Int) {
        guard !results.isEmpty else { return }
        let clamped = ((index % results.count) + results.count) % results.count
        currentIndex = clamped
        pushSelections()
    }

    /// Focus a result by identity (used when the user clicks a row).
    func focus(result: SearchResult) {
        guard let idx = results.firstIndex(where: { $0.id == result.id }) else { return }
        focus(index: idx)
    }

    func focusNext() {
        guard let current = currentIndex else { focus(index: 0); return }
        focus(index: current + 1)
    }

    func focusPrevious() {
        // With nothing focused yet, "previous" wraps to the last match (whereas
        // "next" starts at the first) — the expected ⌘⇧G vs ⌘G behaviour.
        guard let current = currentIndex else { focus(index: results.count - 1); return }
        focus(index: current - 1)
    }

    func clear() {
        query = ""
        results = []
        currentIndex = nil
        onFocusResult?([], nil)
    }

    /// Re-push the current highlights (e.g. after the PDFView's document was
    /// reloaded for a dark-content toggle, which clears `highlightedSelections`).
    func reapplyHighlights() {
        guard currentIndex != nil, !results.isEmpty else { return }
        pushSelections()
    }

    /// Rebuild `PDFSelection`s for every hit and the active one, then notify.
    private func pushSelections() {
        guard let document else { return }
        var all: [PDFSelection] = []
        var active: PDFSelection?
        for (i, result) in results.enumerated() {
            guard let page = document.page(at: result.pageIndex),
                  let selection = page.selection(for: result.pageRange) else { continue }
            all.append(selection)
            if i == currentIndex { active = selection.copy() as? PDFSelection ?? selection }
        }
        onFocusResult?(all, active)
    }
}
