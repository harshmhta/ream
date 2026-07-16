import XCTest
import PDFKit
@testable import Ream

/// Tests for the view coordinator's state capture/restore and view-mode mapping.
@MainActor
final class PDFViewCoordinatorTests: XCTestCase {

    private func makeCoordinator(pages: Int = 5) throws -> PDFViewCoordinator {
        let doc = try XCTUnwrap(PDFTextFixture.makeDocument(
            pages: (0..<pages).map { "Page \($0) body text." }))
        let coordinator = PDFViewCoordinator()
        coordinator.pdfView.document = doc
        return coordinator
    }

    func testCaptureThenApplyRoundTripsViewMode() throws {
        let coordinator = try makeCoordinator()
        coordinator.perform(.setViewMode(.twoUp))
        var state = try XCTUnwrap(coordinator.captureReadingState())
        XCTAssertEqual(state.viewModeRaw, ViewMode.twoUp.rawValue)

        // Change mode, then restore — should return to twoUp.
        coordinator.perform(.setViewMode(.singlePage))
        state.viewModeRaw = ViewMode.twoUp.rawValue
        coordinator.applyReadingState(state)
        XCTAssertEqual(coordinator.viewMode, .twoUp)
    }

    /// Restoring a non-auto-scaled state must set the exact scale (applied before
    /// navigation, per the ordering fix).
    func testApplyReadingStateRestoresExplicitScale() throws {
        let coordinator = try makeCoordinator()
        var state = DocumentReadingState()
        state.autoScales = false
        state.scaleFactor = 1.75
        state.pageIndex = 2
        coordinator.applyReadingState(state)
        XCTAssertFalse(coordinator.pdfView.autoScales)
        XCTAssertEqual(coordinator.pdfView.scaleFactor, 1.75, accuracy: 0.001)
    }

    func testApplyReadingStateClampsScaleToBounds() throws {
        let coordinator = try makeCoordinator()
        var state = DocumentReadingState()
        state.autoScales = false
        state.scaleFactor = 1000 // absurd; must clamp to maxScaleFactor
        coordinator.applyReadingState(state)
        XCTAssertLessThanOrEqual(coordinator.pdfView.scaleFactor, coordinator.pdfView.maxScaleFactor)
    }

    func testApplyReadingStateOnEmptyDocumentDoesNotCrash() {
        let coordinator = PDFViewCoordinator()
        coordinator.pdfView.document = PDFDocument() // zero pages
        var state = DocumentReadingState()
        state.pageIndex = 3
        coordinator.applyReadingState(state) // must not crash on pageCount - 1 == -1
    }

    func testCaptureReturnsNilWithoutDocument() {
        let coordinator = PDFViewCoordinator()
        XCTAssertNil(coordinator.captureReadingState())
    }

    func testViewModeMapping() {
        XCTAssertEqual(ViewMode.singlePage.displayMode, .singlePage)
        XCTAssertEqual(ViewMode.continuous.displayMode, .singlePageContinuous)
        XCTAssertEqual(ViewMode.twoUp.displayMode, .twoUp)
        XCTAssertEqual(ViewMode.book.displayMode, .twoUp)
        XCTAssertTrue(ViewMode.book.displaysAsBook)
        XCTAssertFalse(ViewMode.twoUp.displaysAsBook)
    }
}
