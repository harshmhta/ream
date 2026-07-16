import XCTest
import PDFKit
import ReamCore
@testable import Ream

/// End-to-end search-hit indexing tests: prove that ReamCore's text matches map
/// onto real `PDFSelection`s on the right pages (the app-side half of search).
@MainActor
final class SearchServiceTests: XCTestCase {

    /// A document with a known word on a known page, and the same word twice on
    /// another page.
    private func makeDoc() throws -> PDFDocument {
        let doc = try XCTUnwrap(PDFTextFixture.makeDocument(pages: [
            "The quick brown fox.",
            "A fox and another fox appear here."
        ]), "failed to build text fixture")
        // Sanity: the text layer must be extractable for the test to mean anything.
        try XCTAssertEqual(XCTUnwrap(doc.page(at: 0)?.string?.contains("fox")), true)
        return doc
    }

    /// Search results carry a page range that resolves to a `PDFSelection` whose
    /// text is exactly the query — that is "search-hit indexing" working.
    func testResultRangesResolveToSelectionsOnCorrectPages() throws {
        let doc = try makeDoc()
        let results = collectResults(in: doc, query: "fox", options: .init())

        // 3 occurrences: one on page 0, two on page 1.
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.filter { $0.pageIndex == 0 }.count, 1)
        XCTAssertEqual(results.filter { $0.pageIndex == 1 }.count, 2)

        for result in results {
            let page = try XCTUnwrap(doc.page(at: result.pageIndex))
            let selection = try XCTUnwrap(page.selection(for: result.pageRange),
                                          "range must resolve to a selection")
            XCTAssertEqual(selection.string?.lowercased(), "fox")
        }
    }

    func testWholeWordExcludesSubstringMatches() throws {
        let doc = try XCTUnwrap(PDFTextFixture.makeDocument(pages: [
            "dog doghouse hotdog"
        ]))
        let all = collectResults(in: doc, query: "dog", options: .init())
        let whole = collectResults(in: doc, query: "dog", options: .init(wholeWord: true))
        XCTAssertGreaterThan(all.count, whole.count)
        XCTAssertEqual(whole.count, 1)
    }

    func testEmptyQueryClearsResults() throws {
        let doc = try makeDoc()
        let results = collectResults(in: doc, query: "   ", options: .init())
        XCTAssertTrue(results.isEmpty)
    }

    /// Clearing the query must reset `isSearching` (otherwise the sidebar spins
    /// a progress indicator forever).
    func testClearingQueryResetsIsSearching() throws {
        let doc = try makeDoc()
        let service = SearchService()
        service.attach(to: doc)
        _ = collectResultsOn(service, query: "fox", options: .init())
        // Now clear; the empty-query guard should flip isSearching off.
        service.query = ""
        // Give the debounce a moment.
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(service.isSearching)
        XCTAssertTrue(service.results.isEmpty)
    }

    /// Find Previous from the first match wraps to the last, and Find Next wraps
    /// back to the first — ⌘G / ⌘⇧G cycle through all hits.
    func testFindNavigationWrapsBothDirections() throws {
        let doc = try makeDoc()
        let service = SearchService()
        service.attach(to: doc)
        let results = collectResultsOn(service, query: "fox", options: .init())
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(service.currentIndex, 0) // auto-focused first on completion

        service.focusPrevious()                 // wrap 0 -> last
        XCTAssertEqual(service.currentIndex, results.count - 1)

        service.focusNext()                      // wrap last -> 0
        XCTAssertEqual(service.currentIndex, 0)
    }

    // MARK: - Helpers

    /// Like `collectResults`, but drives an existing service so the caller can
    /// keep interacting with it afterward.
    @discardableResult
    private func collectResultsOn(_ service: SearchService, query: String, options: TextSearchOptions) -> [SearchResult] {
        let expectation = expectation(description: "search completes")
        var lastResults: [SearchResult] = []
        var stableTicks = 0
        service.options = options
        service.query = query
        let token = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if service.isSearching { stableTicks = 0; return }
            if service.results.count == lastResults.count { stableTicks += 1 } else { stableTicks = 0 }
            lastResults = service.results
            if stableTicks >= 4 { t.invalidate(); expectation.fulfill() }
        }
        RunLoop.current.add(token, forMode: .common)
        wait(for: [expectation], timeout: 3.0)
        return service.results
    }

    /// Drive `SearchService` synchronously by waiting for its published results.
    private func collectResults(in doc: PDFDocument, query: String, options: TextSearchOptions) -> [SearchResult] {
        let service = SearchService()
        service.attach(to: doc)
        let expectation = expectation(description: "search completes")
        // The service debounces; poll until it settles (results published, not
        // searching) or the empty-query fast path fires.
        var lastResults: [SearchResult] = []
        var token: Timer?
        service.options = options
        service.query = query

        var stableTicks = 0
        token = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if service.isSearching { stableTicks = 0; return }
            if service.results.count == lastResults.count {
                stableTicks += 1
            } else {
                stableTicks = 0
            }
            lastResults = service.results
            // Consider it settled after two consecutive stable, non-searching ticks
            // past the 150ms debounce.
            if stableTicks >= 4 {
                t.invalidate()
                expectation.fulfill()
            }
        }
        RunLoop.current.add(token!, forMode: .common)
        wait(for: [expectation], timeout: 3.0)
        return service.results
    }
}
