import SwiftUI
import PDFKit

/// The annotation tool strip shown above the PDF canvas. Picks the active tool,
/// the markup color palette (⌃1–⌃5), and the shared style knobs (stroke width,
/// opacity, fill) surfaced for the shape/ink tools.
struct AnnotationToolbar: View {
    @ObservedObject var controller: AnnotationController
    @Binding var showStampPicker: Bool
    @Binding var showInspector: Bool

    private let markupTools: [AnnotationTool] = [.highlight, .underline, .strikethrough, .squiggly]
    private let drawTools: [AnnotationTool] = [.ink, .eraser]
    private let shapeTools: [AnnotationTool] = [.rectangle, .ellipse, .line, .arrow, .polygon, .polyline]
    private let textTools: [AnnotationTool] = [.freeText, .callout, .note]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                toolButton(.select)
                Divider().frame(height: 20)
                group(markupTools)
                Divider().frame(height: 20)
                colorPalette
                Divider().frame(height: 20)
                group(drawTools)
                Divider().frame(height: 20)
                group(shapeTools)
                Divider().frame(height: 20)
                group(textTools)
                stampButton
                Spacer()
                inspectorButton
            }
            styleBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Tool buttons

    private func group(_ tools: [AnnotationTool]) -> some View {
        HStack(spacing: 6) { ForEach(tools) { toolButton($0) } }
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        Button {
            controller.tool = tool
        } label: {
            Image(systemName: tool.systemImage)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(controller.tool == tool ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help(tool.title)
    }

    private var stampButton: some View {
        Button {
            showStampPicker.toggle()
        } label: {
            Image(systemName: AnnotationTool.stamp.systemImage).frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(showStampPicker ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Stamps")
    }

    private var inspectorButton: some View {
        Button {
            showInspector.toggle()
        } label: {
            Image(systemName: "sidebar.right").frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .padding(4)
        .background(showInspector ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Annotation List")
    }

    // MARK: Color palette

    private var colorPalette: some View {
        HStack(spacing: 5) {
            ForEach(AnnotationPalette.swatches) { swatch in
                Button {
                    controller.paletteSelection = swatch.id
                    controller.style.color = swatch.nsColor
                    // If text is selected, apply immediately with last markup tool.
                    _ = controller.applyMarkupToSelection(
                        controller.lastMarkupTool.isTextMarkup ? controller.lastMarkupTool : .highlight,
                        color: swatch.nsColor)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(
                                controller.paletteSelection == swatch.id ? Color.primary : Color.primary.opacity(0.2),
                                lineWidth: controller.paletteSelection == swatch.id ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .help("\(swatch.name)  (⌃\(swatch.id))")
            }
        }
    }

    // MARK: Style bar (width / opacity / fill)

    private var styleBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "lineweight").foregroundStyle(.secondary)
                Slider(value: $controller.style.lineWidth, in: 0.5...12) { }
                    .frame(width: 90)
                Text("\(controller.style.lineWidth, specifier: "%.1f")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $controller.style.opacity, in: 0.1...1) { }
                    .frame(width: 80)
            }
            Toggle(isOn: Binding(
                get: { controller.style.fillColor != nil },
                set: { on in controller.style.fillColor = on ? controller.style.color.withAlphaComponent(0.3) : nil }
            )) {
                Text("Fill").font(.caption)
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
        .font(.caption)
    }
}
