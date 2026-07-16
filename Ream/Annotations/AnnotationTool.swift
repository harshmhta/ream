import SwiftUI
import PDFKit

/// The annotation tools the user can pick up from the toolbar / command palette.
///
/// A tool describes *what the next pointer interaction creates*. `select` is the
/// idle state (click annotations to select/drag them). Text-markup tools act on
/// the current text selection; the geometric tools drag out a shape; the sticky
/// note and stamp tools drop at the click point.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case strikethrough
    case squiggly
    case note
    case ink
    case eraser
    case rectangle
    case ellipse
    case line
    case arrow
    case polygon
    case polyline
    case freeText
    case callout
    case stamp

    var id: String { rawValue }

    /// Whether the tool applies to the current text selection (markup) rather
    /// than a freshly dragged/clicked region.
    var isTextMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikethrough, .squiggly: return true
        default: return false
        }
    }

    /// Whether the tool is committed by dragging out a rectangle/segment.
    var isDragShape: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .callout, .freeText: return true
        default: return false
        }
    }

    /// Whether the tool builds a multi-click vertex path (finish with double
    /// click or Return).
    var isVertexShape: Bool {
        self == .polygon || self == .polyline
    }

    /// SF Symbol for the toolbar button.
    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .squiggly: return "underline"
        case .note: return "note.text"
        case .ink: return "pencil.tip"
        case .eraser: return "eraser"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "line.diagonal.arrow"
        case .polygon: return "pentagon"
        case .polyline: return "scribble.variable"
        case .freeText: return "textformat"
        case .callout: return "text.bubble"
        case .stamp: return "checkmark.seal"
        }
    }

    /// User-facing title (menus, palette, tooltips).
    var title: String {
        switch self {
        case .select: return "Select"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .squiggly: return "Squiggly Underline"
        case .note: return "Sticky Note"
        case .ink: return "Freehand Ink"
        case .eraser: return "Eraser"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .polygon: return "Polygon"
        case .polyline: return "Polyline"
        case .freeText: return "Text Box"
        case .callout: return "Callout"
        case .stamp: return "Stamp"
        }
    }
}

/// The five-swatch markup palette (Skim/Highlights style), applied to the
/// current selection with the last-used markup tool via ⌃1–⌃5.
///
/// > Shortcut note: the viewer already binds ⌘1/⌘2 to Fit Page / Fit Width, so
/// > Ream uses **⌃1–⌃5** for the color palette rather than ⌘1–⌘5 to avoid
/// > stealing the shipped zoom bindings.
struct AnnotationPalette {
    /// A named markup color. `nsColor` is what gets written to the annotation;
    /// the RGBA components keep it codable/portable for XFDF.
    struct Swatch: Identifiable, Equatable {
        let id: Int          // 1...5, matches the ⌃N shortcut
        let name: String
        let red: Double
        let green: Double
        let blue: Double

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }

    /// The default five swatches. Warm→cool, all legible over black text.
    static let swatches: [Swatch] = [
        Swatch(id: 1, name: "Yellow", red: 1.0, green: 0.90, blue: 0.20),
        Swatch(id: 2, name: "Green",  red: 0.50, green: 0.88, blue: 0.40),
        Swatch(id: 3, name: "Blue",   red: 0.40, green: 0.72, blue: 1.0),
        Swatch(id: 4, name: "Pink",   red: 1.0, green: 0.55, blue: 0.78),
        Swatch(id: 5, name: "Orange", red: 1.0, green: 0.65, blue: 0.25)
    ]

    static func swatch(id: Int) -> Swatch? { swatches.first { $0.id == id } }
}
