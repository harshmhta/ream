import XCTest

/// Smoke-level UI tests. These launch the app and assert it comes up without
/// crashing. Opening a document through the sandboxed open panel is not
/// scriptable in a hermetic CI run, so document-open coverage lives in the unit
/// tests (`PDFReferenceDocumentTests`); this target guards app launch + menus.
final class ReamUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testCommandPaletteMenuItemExists() throws {
        let app = XCUIApplication()
        app.launch()
        // The ⌘K "Command Palette…" command is registered in the menu bar
        // regardless of whether a document window is open. (The palette overlay
        // itself is document-scoped in v0.1, so it needs an open PDF to render;
        // that path is exercised interactively and by CommandPaletteServiceTests.)
        let menuItem = app.menuItems["Command Palette…"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5),
                      "the Command Palette menu command should be present")
    }
}
