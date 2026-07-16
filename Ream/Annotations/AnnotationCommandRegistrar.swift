import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Registers annotation actions into the ⌘K command palette
/// (`CommandPaletteService.shared`).
///
/// The command set is registered **once** and its closures resolve the
/// currently-focused document's controller through the weakly-held ``active``
/// reference at invocation time. This matters because the palette service is an
/// app-wide singleton: capturing a specific per-window controller in a
/// long-lived closure would (a) leak that window's document forever and
/// (b) make ⌘K act on a stale document once another window takes focus. Each
/// document view sets ``active`` when it appears / becomes key (see
/// ``setActive(_:showInspector:)``), mirroring how the menu commands use
/// `@FocusedValue`.
enum AnnotationCommandRegistrar {

    /// The focused document's controller. Weak so closing a window releases its
    /// document rather than pinning it in the singleton.
    @MainActor private(set) static weak var active: AnnotationController?
    /// The focused window's inspector toggle.
    @MainActor private static var activeShowInspector: Binding<Bool>?

    /// Mark `controller` as the target for palette commands, and register the
    /// (idempotent) command set on first call.
    @MainActor
    static func setActive(_ controller: AnnotationController, showInspector: Binding<Bool>) {
        active = controller
        activeShowInspector = showInspector
        registerIfNeeded()
    }

    @MainActor private static var didRegister = false

    @MainActor
    private static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        let service = CommandPaletteService.shared
        var commands: [PaletteCommand] = []

        // Tool pickers.
        for tool in AnnotationTool.allCases where tool != .select && tool != .stamp {
            commands.append(PaletteCommand(
                id: "annotate.tool.\(tool.rawValue)",
                title: "Annotate: \(tool.title)",
                category: "Annotate",
                keyboardShortcut: nil
            ) { active?.tool = tool })
        }

        // Palette colors.
        for swatch in AnnotationPalette.swatches {
            commands.append(PaletteCommand(
                id: "annotate.color.\(swatch.id)",
                title: "Highlight Color: \(swatch.name)",
                category: "Annotate",
                keyboardShortcut: "⌃\(swatch.id)"
            ) { active?.applyPaletteColor(id: swatch.id) })
        }

        // List / inspector.
        commands.append(PaletteCommand(
            id: "annotate.toggleInspector",
            title: "Toggle Annotation List",
            category: "Annotate"
        ) { activeShowInspector?.wrappedValue.toggle() })

        // XFDF import / export.
        commands.append(PaletteCommand(
            id: "annotate.exportXFDF",
            title: "Export Annotations to XFDF…",
            category: "Annotate"
        ) { if let active { exportXFDF(active) } })

        commands.append(PaletteCommand(
            id: "annotate.importXFDF",
            title: "Import Annotations from XFDF…",
            category: "Annotate"
        ) { if let active { importXFDF(active) } })

        // Flatten.
        commands.append(PaletteCommand(
            id: "annotate.flattenAll",
            title: "Flatten All Annotations",
            category: "Annotate"
        ) { active?.flatten(onlySelected: false) })

        commands.append(PaletteCommand(
            id: "annotate.flattenSelected",
            title: "Flatten Selected Annotation",
            category: "Annotate"
        ) { active?.flatten(onlySelected: true) })

        service.register(commands)
    }

    // MARK: File panels (shared by menu + palette)

    @MainActor
    static func exportXFDF(_ controller: AnnotationController) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [xfdfType]
        panel.nameFieldStringValue = "annotations.xfdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.exportXFDF(to: url) }
        catch { presentError(error) }
    }

    @MainActor
    static func importXFDF(_ controller: AnnotationController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [xfdfType, .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.importXFDF(from: url) }
        catch { presentError(error) }
    }

    /// The XFDF UTI. Falls back to a dynamic type keyed by extension since
    /// macOS doesn't ship a system type for `.xfdf`.
    static var xfdfType: UTType {
        UTType(filenameExtension: "xfdf") ?? .xml
    }

    @MainActor
    private static func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
