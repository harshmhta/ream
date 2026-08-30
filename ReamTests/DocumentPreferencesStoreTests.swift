import XCTest
@testable import Ream

/// Tests for per-document reading-state persistence (position + zoom + mode).
final class DocumentPreferencesStoreTests: XCTestCase {

    private func makeStore() -> DocumentPreferencesStore {
        // Use an isolated suite so tests don't touch the real user defaults.
        let suiteName = "com.ream.tests.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return DocumentPreferencesStore(defaults: defaults)
    }

    func testRoundTripsReadingState() {
        let store = makeStore()
        var state = DocumentReadingState()
        state.pageIndex = 12
        state.scrollPointY = 340
        state.scaleFactor = 1.75
        state.autoScales = false
        state.viewModeRaw = ViewMode.twoUp.rawValue
        state.invertContent = true

        store.setReadingState(state, for: "file:///doc.pdf")
        let loaded = store.readingState(for: "file:///doc.pdf")

        XCTAssertEqual(loaded, state)
    }

    func testMissingKeyReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.readingState(for: "file:///nope.pdf"))
    }

    func testKeysAreIsolated() {
        let store = makeStore()
        var a = DocumentReadingState(); a.pageIndex = 3
        var b = DocumentReadingState(); b.pageIndex = 99
        store.setReadingState(a, for: "file:///a.pdf")
        store.setReadingState(b, for: "file:///b.pdf")
        XCTAssertEqual(store.readingState(for: "file:///a.pdf")?.pageIndex, 3)
        XCTAssertEqual(store.readingState(for: "file:///b.pdf")?.pageIndex, 99)
    }
}
