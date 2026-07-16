import Foundation

/// Registers the Convert & Export actions in the ⌘K command palette.
///
/// These are app-wide capabilities, so they are registered **once** (idempotently
/// — `CommandPaletteService` de-duplicates by id) and route through
/// ``ConversionCoordinator/active``, the most-recently-focused window's
/// coordinator. This avoids the twin hazards of per-window registration against a
/// shared singleton: one window's teardown stripping commands for every window,
/// and a stale closure acting on a background or closed window.
enum ConversionCommands {

    @MainActor
    static func registerIfNeeded() {
        let palette = CommandPaletteService.shared
        palette.register([
            PaletteCommand(id: "convert.compress",
                           title: "Compress PDF…",
                           category: "Convert & Export",
                           keyboardShortcut: "⌃⌘C") {
                ConversionCoordinator.active?.presentCompress()
            },
            PaletteCommand(id: "convert.imagesToPDF",
                           title: "New PDF from Images…",
                           category: "Convert & Export",
                           keyboardShortcut: "⇧⌘I") {
                ConversionCoordinator.active?.presentImagesToPDF()
            },
            PaletteCommand(id: "convert.pdfToImages",
                           title: "Export Pages as Images…",
                           category: "Convert & Export",
                           keyboardShortcut: "⇧⌘E") {
                ConversionCoordinator.active?.presentPDFToImages()
            },
        ])
    }
}
