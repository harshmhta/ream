import XCTest
import PDFKit
import Combine
@testable import Ream

/// Tests for the per-window hub that the menu bar drives.
@MainActor
final class DocumentWindowModelTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    private func makeModel() throws -> DocumentWindowModel {
        let data = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Hello world."])?.dataRepresentation())
        let refDoc = PDFReferenceDocument()
        refDoc.pdfDocument = try XCTUnwrap(InvertingPDFDocument(data: data))
        return DocumentWindowModel(document: refDoc)
    }

    /// Toggling dark content must flip the document flag and emit a change so the
    /// menu (an `@FocusedObject` observer) re-renders its Invert/Restore title.
    func testToggleDarkContentFlipsFlagAndPublishes() throws {
        let model = try makeModel()
        var published = false
        model.objectWillChange
            .sink { published = true }
            .store(in: &cancellables)

        XCTAssertFalse(model.document.invertContent)
        model.toggleDarkContent()
        XCTAssertTrue(model.document.invertContent)
        XCTAssertTrue(published, "toggling dark content should publish a change")
    }

    func testSetViewModeUpdatesCoordinatorAndPublishes() throws {
        let model = try makeModel()
        var published = false
        model.objectWillChange.sink { published = true }.store(in: &cancellables)

        model.setViewMode(.twoUp)
        XCTAssertEqual(model.coordinator.viewMode, .twoUp)
        XCTAssertTrue(published)
    }

    func testFocusSearchRevealsSearchInspector() throws {
        let model = try makeModel()
        model.isInspectorVisible = false
        model.focusSearch()
        XCTAssertTrue(model.isInspectorVisible)
        XCTAssertEqual(model.inspectorMode, .search)
        XCTAssertTrue(model.requestSearchFocus)
    }

    func testToggleInspectorFlips() throws {
        let model = try makeModel()
        let initial = model.isInspectorVisible
        model.toggleInspector()
        XCTAssertNotEqual(model.isInspectorVisible, initial)
    }

    func testOutlineNodesBuiltFromDocument() throws {
        // The plain text fixture has no outline; nodes should be nil, not a crash.
        let model = try makeModel()
        XCTAssertNil(model.outlineNodes)
    }

    // MARK: - Wholesale document replacement

    /// Strip All Metadata, Remove Password and Flatten Annotations all swap
    /// `pdfDocument` for a rebuilt document. Everything the window cached from
    /// the old one has to follow, or the feature silently dies: search held the
    /// old document *weakly*, so after a strip it had no document at all and
    /// every query came back empty.
    func testSearchFollowsDocumentReplacement() throws {
        let model = try makeModel()
        XCTAssertEqual(collectResults(model, query: "Hello").count, 1)

        let replacement = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Hello again, hello."]))
        model.document.pdfDocument = replacement

        XCTAssertEqual(collectResults(model, query: "hello").count, 2,
                       "search must re-attach to the replacement document")
    }

    /// The cached page text is keyed to the old document; a replacement with
    /// different text must not answer from it.
    func testSearchDropsCachedPageTextOnReplacement() throws {
        let model = try makeModel()
        XCTAssertEqual(collectResults(model, query: "Hello").count, 1)

        let replacement = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Nothing to see."]))
        model.document.pdfDocument = replacement

        XCTAssertTrue(collectResults(model, query: "Hello").isEmpty,
                      "stale cached page text must not survive a document swap")
    }

    /// A strip rebuilds the document without its bookmarks; the sidebar must not
    /// keep offering the old tree (whose destinations point into a document that
    /// is no longer on screen).
    func testOutlineFollowsDocumentReplacement() throws {
        let model = try makeModel()
        let outlined = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["A", "B"]))
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: try XCTUnwrap(outlined.page(at: 0)), at: .zero)
        root.insertChild(child, at: 0)
        outlined.outlineRoot = root

        model.document.pdfDocument = outlined
        XCTAssertEqual(model.outlineNodes?.count, 1)
        XCTAssertEqual(model.outlineNodes?.first?.label, "Chapter 1")

        let plain = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["No outline."]))
        model.document.pdfDocument = plain
        XCTAssertNil(model.outlineNodes, "a document without bookmarks must clear the tree")
    }

    // MARK: - Helpers

    /// Drive the model's search service and wait for it to settle.
    private func collectResults(_ model: DocumentWindowModel, query: String) -> [SearchResult] {
        let service = model.search
        let expectation = expectation(description: "search settles")
        var lastCount = -1
        var stableTicks = 0
        service.query = query
        let token = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if service.isSearching { stableTicks = 0; return }
            if service.results.count == lastCount { stableTicks += 1 } else { stableTicks = 0 }
            lastCount = service.results.count
            if stableTicks >= 4 { t.invalidate(); expectation.fulfill() }
        }
        RunLoop.current.add(token, forMode: .common)
        wait(for: [expectation], timeout: 3.0)
        return service.results
    }
}
