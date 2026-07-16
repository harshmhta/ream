import XCTest
@testable import Ream

@MainActor
final class CommandPaletteServiceTests: XCTestCase {

    /// Use a fresh service per test rather than the shared singleton so tests
    /// don't leak registrations into each other.
    private func makeService() -> CommandPaletteService {
        // The initializer is private; the shared instance is the supported
        // surface. Clear it to a known state for deterministic assertions.
        let service = CommandPaletteService.shared
        for command in service.commands {
            service.unregister(id: command.id)
        }
        service.isPresented = false
        return service
    }

    func testStartsEmpty() {
        let service = makeService()
        XCTAssertTrue(service.commands.isEmpty)
    }

    func testRegisterAddsCommand() {
        let service = makeService()
        service.register(PaletteCommand(id: "test.a", title: "Alpha") {})
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertEqual(service.commands.first?.title, "Alpha")
    }

    func testRegisterSameIDReplacesRatherThanDuplicates() {
        let service = makeService()
        service.register(PaletteCommand(id: "test.a", title: "Alpha") {})
        service.register(PaletteCommand(id: "test.a", title: "Alpha v2") {})
        XCTAssertEqual(service.commands.count, 1)
        XCTAssertEqual(service.commands.first?.title, "Alpha v2")
    }

    func testUnregisterRemovesCommand() {
        let service = makeService()
        service.register(PaletteCommand(id: "test.a", title: "Alpha") {})
        service.unregister(id: "test.a")
        XCTAssertTrue(service.commands.isEmpty)
    }

    func testFilterMatchesTitleCaseInsensitively() {
        let service = makeService()
        service.register(PaletteCommand(id: "p.rotate", title: "Rotate Page", category: "Pages") {})
        service.register(PaletteCommand(id: "a.hl", title: "Highlight", category: "Annotate") {})

        XCTAssertEqual(service.filtered(by: "rotate").count, 1)
        XCTAssertEqual(service.filtered(by: "ROTATE").first?.id, "p.rotate")
        XCTAssertEqual(service.filtered(by: "pages").first?.id, "p.rotate") // category match
        XCTAssertEqual(service.filtered(by: "").count, 2) // empty query returns all
    }

    func testRunInvokesActionAndDismisses() {
        let service = makeService()
        var ran = false
        service.isPresented = true
        let command = PaletteCommand(id: "test.run", title: "Run Me") { ran = true }
        service.run(command)
        XCTAssertTrue(ran)
        XCTAssertFalse(service.isPresented)
    }

    func testToggleFlipsPresentation() {
        let service = makeService()
        XCTAssertFalse(service.isPresented)
        service.toggle()
        XCTAssertTrue(service.isPresented)
        service.toggle()
        XCTAssertFalse(service.isPresented)
    }
}
