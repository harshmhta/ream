import SwiftUI
import PDFKit

/// The **Annotations** menu. Targets the focused window's
/// ``AnnotationController`` via `@FocusedValue` and is disabled when no document
/// window is key.
///
/// > Shortcut note: the viewer already binds ⌘1 / ⌘2 to Fit Page / Fit Width,
/// > so the markup color palette uses **⌃1–⌃5** rather than ⌘1–⌘5 to avoid
/// > colliding with the shipped zoom bindings.
struct AnnotationCommands: Commands {
    @FocusedValue(\.annotationController) private var controller

    var body: some Commands {
        CommandMenu("Annotations") {
            Group {
                Button("Highlight") { controller?.tool = .highlight }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(controller == nil)
                Button("Underline") { controller?.tool = .underline }
                    .disabled(controller == nil)
                Button("Strikethrough") { controller?.tool = .strikethrough }
                    .disabled(controller == nil)
                Button("Squiggly Underline") { controller?.tool = .squiggly }
                    .disabled(controller == nil)
            }

            Divider()

            Group {
                Button("Sticky Note") { controller?.tool = .note }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(controller == nil)
                Button("Freehand Ink") { controller?.tool = .ink }
                    .disabled(controller == nil)
                Button("Text Box") { controller?.tool = .freeText }
                    .disabled(controller == nil)
            }

            Divider()

            // Markup color palette — ⌃1…⌃5 apply the last-used markup tool with
            // the swatch color to the current text selection.
            Menu("Highlight Colors") {
                ForEach(AnnotationPalette.swatches) { swatch in
                    Button("\(swatch.id)  \(swatch.name)") {
                        controller?.applyPaletteColor(id: swatch.id)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(swatch.id)")), modifiers: .control)
                    .disabled(controller == nil)
                }
            }

            Divider()

            Group {
                Button("Import from XFDF…") {
                    if let controller { AnnotationCommandRegistrar.importXFDF(controller) }
                }
                .disabled(controller == nil)
                Button("Export to XFDF…") {
                    if let controller { AnnotationCommandRegistrar.exportXFDF(controller) }
                }
                .disabled(controller == nil)
            }

            Divider()

            Group {
                Button("Flatten All Annotations") { controller?.flatten(onlySelected: false) }
                    .disabled(controller == nil)
                Button("Flatten Selected Annotation") { controller?.flatten(onlySelected: true) }
                    .disabled(controller?.selectedAnnotation == nil)
            }

            Divider()

            Group {
                // A self-contained annotation undo/redo stack. Deliberately not
                // bound to ⌘Z / ⌘⇧Z so it doesn't shadow the document's system
                // undo; surfaced as plain menu items instead.
                Button("Undo Annotation") { controller?.undo() }
                    .disabled(controller?.canUndo != true)
                Button("Redo Annotation") { controller?.redo() }
                    .disabled(controller?.canRedo != true)
                // No bare-Delete key equivalent here: an unmodified Delete menu
                // shortcut would intercept the key while editing note text.
                // On-canvas Delete is handled by ReamPDFView.keyDown instead.
                Button("Delete Selected Annotation") { controller?.deleteSelected() }
                    .disabled(controller?.selectedAnnotation == nil)
            }
        }
    }
}
