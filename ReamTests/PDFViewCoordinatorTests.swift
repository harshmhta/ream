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

    // MARK: - Reload after page mutations

    /// `.reload` swaps the document out and back to force a relayout after a page
    /// op. PDFKit resets its layout mode and zoom on that swap, so the coordinator
    /// has to put them back — otherwise deleting a page silently kicks a reader
    /// out of two-page/book mode and loses their zoom.
    func testReloadPreservesViewModeAndZoom() throws {
        let coordinator = try makeCoordinator()
        coordinator.perform(.setViewMode(.book))
        coordinator.perform(.zoomIn)
        let scale = coordinator.pdfView.scaleFactor

        coordinator.perform(.reload)

        XCTAssertEqual(coordinator.viewMode, .book)
        XCTAssertEqual(coordinator.pdfView.displayMode, .twoUp)
        XCTAssertTrue(coordinator.pdfView.displaysAsBook)
        XCTAssertFalse(coordinator.pdfView.autoScales)
        XCTAssertEqual(coordinator.pdfView.scaleFactor, scale, accuracy: 0.001)
    }

    /// A page op that leaves the reader's page in place must not bounce them back
    /// to page 1 — the document swap that forces the relayout resets navigation.
    func testReloadKeepsReaderOnCurrentPage() throws {
        let coordinator = try makeCoordinator(pages: 4)
        coordinator.perform(.goToPage(2))
        XCTAssertEqual(coordinator.currentPageIndex, 2)

        // Simulate an insert at the end (the reader's page index is unchanged).
        let extra = try XCTUnwrap(PDFTextFixture.makeDocument(pages: ["Appended."])?.page(at: 0))
        coordinator.pdfView.document?.insert(extra, at: 4)
        coordinator.perform(.reload)

        XCTAssertEqual(coordinator.pdfView.document?.pageCount, 5)
        XCTAssertEqual(coordinator.currentPageIndex, 2)
    }

    /// Deleting the page under the reader detaches it; `index(for:)` then answers
    /// `NSNotFound`, so the coordinator must report "no current page" rather than
    /// a bogus index — and reloading must still leave the view on a real page.
    func testReloadAfterCurrentPageDeletedStaysInBounds() throws {
        let coordinator = try makeCoordinator(pages: 3)
        coordinator.perform(.goToPage(2))
        let detached = try XCTUnwrap(coordinator.pdfView.currentPage)

        coordinator.pdfView.document?.removePage(at: 2)
        XCTAssertEqual(coordinator.pdfView.document?.index(for: detached), NSNotFound)
        XCTAssertNil(coordinator.currentPageIndex, "a detached page is not a valid current page")

        coordinator.perform(.reload)

        XCTAssertEqual(coordinator.pdfView.document?.pageCount, 2)
        if let index = coordinator.currentPageIndex {
            XCTAssertLessThan(index, 2)
        }
    }

    func testReloadWithoutDocumentDoesNotCrash() {
        let coordinator = PDFViewCoordinator()
        coordinator.perform(.reload)
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
