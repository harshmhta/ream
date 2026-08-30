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
}
