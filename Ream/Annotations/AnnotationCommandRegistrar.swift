import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Registers annotation actions into the ⌘K command palette
/// (`CommandPaletteService.shared`). Called when a document view appears; the
/// registry de-dupes by id, so re-registering on appear is safe. The commands
/// capture the *live* controller so they always act on the focused document's
/// annotations.
enum AnnotationCommandRegistrar {

    @MainActor
    static func register(_ controller: AnnotationController, showInspector: Binding<Bool>) {
        let service = CommandPaletteService.shared
        var commands: [PaletteCommand] = []

        // Tool pickers.
        for tool in AnnotationTool.allCases where tool != .select && tool != .stamp {
            commands.append(PaletteCommand(
                id: "annotate.tool.\(tool.rawValue)",
                title: "Annotate: \(tool.title)",
                category: "Annotate",
                keyboardShortcut: nil
            ) { controller.tool = tool })
        }

        // Palette colors.
        for swatch in AnnotationPalette.swatches {
            commands.append(PaletteCommand(
                id: "annotate.color.\(swatch.id)",
                title: "Highlight Color: \(swatch.name)",
                category: "Annotate",
                keyboardShortcut: "⌃\(swatch.id)"
            ) { controller.applyPaletteColor(id: swatch.id) })
        }

        // List / inspector.
        commands.append(PaletteCommand(
            id: "annotate.toggleInspector",
            title: "Toggle Annotation List",
            category: "Annotate"
        ) { showInspector.wrappedValue.toggle() })

        // XFDF import / export.
        commands.append(PaletteCommand(
            id: "annotate.exportXFDF",
            title: "Export Annotations to XFDF…",
            category: "Annotate"
        ) { exportXFDF(controller) })

        commands.append(PaletteCommand(
            id: "annotate.importXFDF",
            title: "Import Annotations from XFDF…",
            category: "Annotate"
        ) { importXFDF(controller) })

        // Flatten.
        commands.append(PaletteCommand(
            id: "annotate.flattenAll",
            title: "Flatten All Annotations",
            category: "Annotate"
        ) { controller.flatten(onlySelected: false) })

        commands.append(PaletteCommand(
            id: "annotate.flattenSelected",
            title: "Flatten Selected Annotation",
            category: "Annotate"
        ) { controller.flatten(onlySelected: true) })

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
