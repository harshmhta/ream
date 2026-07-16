import PDFKit
import AppKit

/// Builds real `PDFAnnotation`s for each Ream tool. Centralizing construction
/// here keeps the coordinate math and PDF-spec quirks (quad-point ordering,
/// non-native subtype geometry, popup pairing) in one auditable place and lets
/// tests build annotations without any UI.
///
/// All inputs are in **page space** (origin bottom-left), which is what every
/// PDFKit annotation API expects.
enum AnnotationFactory {

    /// Default style knobs the interaction layer threads through.
    struct Style {
        var color: NSColor = AnnotationPalette.swatches[0].nsColor
        var fillColor: NSColor? = nil
        var lineWidth: CGFloat = 2
        var opacity: CGFloat = 1
        var fontSize: CGFloat = 14
    }

    // MARK: Text markup (highlight / underline / strikethrough / squiggly)

    /// Build markup annotations for a text selection. Returns one annotation per
    /// page the selection covers (markup annotations are single-page). Uses the
    /// real markup subtypes so other readers understand them; squiggly is a
    /// Ream-drawn subclass because PDFKit won't render it natively.
    static func markup(for selection: PDFSelection,
                       tool: AnnotationTool,
                       color: NSColor) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var result: [(PDFPage, PDFAnnotation)] = []
        for page in selection.pages {
            // Gather per-line rects so multi-line selections get one quad each.
            let lineSelections = selection.selectionsByLine().filter { $0.pages.contains(page) }
            var quads: [CGRect] = []
            for line in lineSelections {
                let r = line.bounds(for: page)
                if r.width > 0.5, r.height > 0.5 { quads.append(r) }
            }
            if quads.isEmpty {
                let r = selection.bounds(for: page)
                if r.width > 0.5, r.height > 0.5 { quads.append(r) }
            }
            guard !quads.isEmpty else { continue }

            let bounds = quads.reduce(quads[0]) { $0.union($1) }

            let annotation: PDFAnnotation
            if tool == .squiggly {
                annotation = SquigglyAnnotation(bounds: bounds,
                                                forType: PDFAnnotationSubtype(rawValue: "Squiggly"),
                                                withProperties: nil)
                annotation.setValue("Squiggly", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subtype"))
                // Persist quads (relative to bounds origin) so the subclass can
                // redraw and so XFDF export can emit real QuadPoints.
                annotation.setValue(packQuads(quads, relativeTo: bounds.origin),
                                    forAnnotationKey: ReamAnnotationKey.vertices)
            } else {
                let subtype: PDFAnnotationSubtype
                switch tool {
                case .highlight:      subtype = .highlight
                case .underline:      subtype = .underline
                case .strikethrough:  subtype = .strikeOut
                default:              subtype = .highlight
                }
                annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
                annotation.quadrilateralPoints = quadPointValues(quads, relativeTo: bounds.origin)
            }
            annotation.color = color
            stampMetadata(on: annotation)
            result.append((page, annotation))
        }
        return result
    }

    // MARK: Sticky note

    /// A `Text` (sticky note) annotation anchored at `point`, authored by the
    /// current system user, timestamped now.
    static func note(at point: CGPoint, contents: String = "") -> PDFAnnotation {
        let size: CGFloat = 22
        let bounds = CGRect(x: point.x, y: point.y - size, width: size, height: size)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.color = AnnotationPalette.swatches[0].nsColor
        annotation.contents = contents
        stampMetadata(on: annotation)
        return annotation
    }

    /// A threaded reply to `parent`, carrying the reply linkage key.
    static func reply(to parent: PDFAnnotation, contents: String) -> PDFAnnotation {
        let bounds = parent.bounds.offsetBy(dx: 6, dy: -6)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = contents
        annotation.reamInReplyTo = parent.reamID
        stampMetadata(on: annotation)
        return annotation
    }

    // MARK: Ink

    /// A freehand ink annotation from already-smoothed page-space points.
    static func ink(paths: [[CGPoint]], style: Style) -> PDFAnnotation? {
        let all = paths.flatMap { $0 }
        guard all.count >= 2 else { return nil }
        let bounds = ReamGeometry.boundingBox(of: all, padding: style.lineWidth + 2)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = style.color
        let border = PDFBorder()
        border.lineWidth = style.lineWidth
        annotation.border = border
        // PDFKit ink paths are in annotation space (relative to the bounds
        // origin), so shift the page-space samples into that frame.
        let origin = bounds.origin
        for stroke in paths where stroke.count >= 2 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x - origin.x, y: stroke[0].y - origin.y))
            for p in stroke.dropFirst() {
                path.line(to: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
            }
            annotation.add(path)
        }
        applyOpacity(style.opacity, to: annotation)
        stampMetadata(on: annotation)
        return annotation
    }

    // MARK: Shapes

    /// Rectangle or ellipse from a dragged rect.
    static func boxShape(_ tool: AnnotationTool, rect: CGRect, style: Style) -> PDFAnnotation {
        let subtype: PDFAnnotationSubtype = (tool == .ellipse) ? .circle : .square
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: subtype, withProperties: nil)
        annotation.color = style.color
        annotation.interiorColor = style.fillColor
        let border = PDFBorder(); border.lineWidth = style.lineWidth
        annotation.border = border
        applyOpacity(style.opacity, to: annotation)
        stampMetadata(on: annotation)
        return annotation
    }

    /// Line or arrow between two page-space points.
    static func lineShape(_ tool: AnnotationTool, from a: CGPoint, to b: CGPoint, style: Style) -> PDFAnnotation {
        let bounds = ReamGeometry.boundingBox(of: [a, b], padding: style.lineWidth + 4)
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        annotation.color = style.color
        let border = PDFBorder(); border.lineWidth = style.lineWidth
        annotation.border = border
        // Line endpoints are in annotation space (relative to bounds origin).
        annotation.startPoint = CGPoint(x: a.x - bounds.minX, y: a.y - bounds.minY)
        annotation.endPoint = CGPoint(x: b.x - bounds.minX, y: b.y - bounds.minY)
        if tool == .arrow {
            annotation.startLineStyle = .none
            annotation.endLineStyle = .closedArrow
        }
        applyOpacity(style.opacity, to: annotation)
        stampMetadata(on: annotation)
        return annotation
    }

    /// Polygon (closed) or polyline (open) from vertices in page space.
    static func polyShape(_ tool: AnnotationTool, vertices: [CGPoint], style: Style) -> PDFAnnotation? {
        guard vertices.count >= 2 else { return nil }
        let closed = (tool == .polygon)
        let bounds = ReamGeometry.boundingBox(of: vertices, padding: style.lineWidth + 4)
        let subtype = closed ? "Polygon" : "PolyLine"
        let annotation = PolyShapeAnnotation(bounds: bounds,
                                             forType: PDFAnnotationSubtype(rawValue: subtype),
                                             withProperties: nil)
        annotation.setValue(subtype, forAnnotationKey: PDFAnnotationKey(rawValue: "/Subtype"))
        annotation.color = style.color
        if closed { annotation.interiorColor = style.fillColor }
        let border = PDFBorder(); border.lineWidth = style.lineWidth
        annotation.border = border
        // Store absolute page-space vertices; the subclass draws in page space.
        annotation.setValue(ReamGeometry.packPoints(vertices), forAnnotationKey: ReamAnnotationKey.vertices)
        applyOpacity(style.opacity, to: annotation)
        stampMetadata(on: annotation)
        return annotation
    }

    // MARK: Free text & callout

    /// A free-text box.
    static func freeText(rect: CGRect, contents: String, style: Style) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: .freeText, withProperties: nil)
        annotation.contents = contents
        annotation.font = NSFont.systemFont(ofSize: style.fontSize)
        // Bake a concrete color: dynamic catalog colors (e.g. `labelColor`)
        // resolve to white in a headless appearance stream and vanish on paper.
        annotation.fontColor = concreteColor(style.color, fallback: .black)
        annotation.color = .clear      // transparent background box
        annotation.alignment = .left
        stampMetadata(on: annotation)
        return annotation
    }

    /// Resolve any `NSColor` (including dynamic system colors like `labelColor`)
    /// into a concrete sRGB color safe to bake into a PDF appearance stream.
    ///
    /// Dynamic catalog colors resolve against the *current* appearance; a
    /// headless render context defaults to dark, which turns `labelColor` white
    /// and makes text vanish on paper. Resolve in the light (aqua) appearance so
    /// baked text/ink is legible on a white page regardless of the app's theme.
    static func concreteColor(_ color: NSColor, fallback: NSColor) -> NSColor {
        var resolved: NSColor?
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
        } else {
            resolved = color.usingColorSpace(.sRGB)
        }
        if let resolved, resolved.alphaComponent > 0.01 { return resolved }
        return fallback
    }

    /// A callout = free-text box + a connector line stored under a custom key so
    /// Ream can redraw/edit the leader. The text box uses the dragged rect; the
    /// connector runs from `anchor` to the box.
    static func callout(rect: CGRect, anchor: CGPoint, contents: String, style: Style) -> PDFAnnotation {
        let annotation = freeText(rect: rect, contents: contents, style: style)
        // Connector: anchor point → nearest box edge midpoint.
        let boxEdge = CGPoint(x: rect.minX, y: rect.midY)
        annotation.setValue(ReamGeometry.packPoints([anchor, boxEdge]),
                            forAnnotationKey: ReamAnnotationKey.calloutLine)
        return annotation
    }

    // MARK: Stamp

    /// A rubber-stamp annotation whose appearance is drawn from `image`.
    static func stamp(image: NSImage, at rect: CGRect, name: String) -> PDFAnnotation {
        let annotation = ImageStampAnnotation(bounds: rect.standardized,
                                              forType: .stamp, withProperties: nil)
        annotation.stampImage = image
        annotation.stampName = name
        stampMetadata(on: annotation)
        return annotation
    }

    // MARK: - Helpers

    /// Stamp author + timestamp + a stable Ream id onto a new annotation.
    static func stampMetadata(on annotation: PDFAnnotation) {
        if annotation.userName?.isEmpty ?? true {
            annotation.userName = NSFullUserName()
        }
        annotation.modificationDate = Date()
        _ = annotation.reamID   // mint + persist id
    }

    /// Opacity via the `/CA` constant-alpha key (PDFKit has no opacity setter).
    static func applyOpacity(_ opacity: CGFloat, to annotation: PDFAnnotation) {
        guard opacity < 1 else { return }
        annotation.setValue(NSNumber(value: Double(opacity)),
                            forAnnotationKey: PDFAnnotationKey(rawValue: "/CA"))
    }

    /// Convert per-line rects into PDFKit quad points (NSValue points, 4 per
    /// quad in Z-order: UL, UR, LL, LR), relative to `origin`.
    static func quadPointValues(_ rects: [CGRect], relativeTo origin: CGPoint) -> [NSValue] {
        rects.flatMap { r -> [NSValue] in
            [CGPoint(x: r.minX - origin.x, y: r.maxY - origin.y),
             CGPoint(x: r.maxX - origin.x, y: r.maxY - origin.y),
             CGPoint(x: r.minX - origin.x, y: r.minY - origin.y),
             CGPoint(x: r.maxX - origin.x, y: r.minY - origin.y)].map { NSValue(point: $0) }
        }
    }

    /// Pack the same quad ordering into the string form used by custom subtypes.
    static func packQuads(_ rects: [CGRect], relativeTo origin: CGPoint) -> String {
        let points = rects.flatMap { r in
            [CGPoint(x: r.minX - origin.x, y: r.maxY - origin.y),
             CGPoint(x: r.maxX - origin.x, y: r.maxY - origin.y),
             CGPoint(x: r.minX - origin.x, y: r.minY - origin.y),
             CGPoint(x: r.maxX - origin.x, y: r.minY - origin.y)]
        }
        return ReamGeometry.packPoints(points)
    }
}

/// A stamp annotation that renders a supplied `NSImage` (built-in text stamp or
/// user image). PDFKit's `Stamp` type shows almost nothing without an
/// appearance stream, so we draw the image and let PDFKit bake it on save.
final class ImageStampAnnotation: PDFAnnotation {
    var stampImage: NSImage?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image = stampImage else {
            super.draw(with: box, in: context)
            return
        }
        context.saveGState()
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(cg, in: bounds)
        }
        context.restoreGState()
    }
}
