import PDFKit
import AppKit

/// Annotation subtypes PDFKit renders natively vs. those Ream must draw itself.
///
/// Per the PDFKit headers, `Squiggly`, `Polygon`, and `PolyLine` are **not**
/// natively rendered — PDFKit drops their geometry on save and shows nothing
/// unless there is an appearance stream. Ream implements them as `PDFAnnotation`
/// subclasses that (a) persist their geometry under a custom `/Ream_Vertices`
/// key and (b) override `draw(with:in:)`. When such an annotation is saved,
/// PDFKit bakes the drawing into an appearance stream (so any reader shows it);
/// when Ream re-opens the file, ``ReamAnnotationFactory`` re-instantiates the
/// subclass so the geometry stays editable.

// MARK: - Squiggly underline

/// A wavy underline under marked-up text. Geometry travels as `quadrilateral
/// Points`-style quads packed into `/Ream_Vertices` (x,y pairs, 4 points per
/// quad, relative to the annotation bounds origin — same convention as
/// PDFKit markup quad points).
final class SquigglyAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        let quads = ReamGeometry.unpackPoints(stringValue(for: ReamAnnotationKey.vertices))
        guard quads.count >= 4 else { return }
        let stroke = (color ?? .systemYellow)
        context.saveGState()
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(1.2)
        context.setLineJoin(.round)
        // Each group of 4 points is a quad (UL, UR, LL, LR); squiggle along its
        // baseline (LL → LR).
        var i = 0
        while i + 3 < quads.count {
            let ll = CGPoint(x: bounds.minX + quads[i + 2].x, y: bounds.minY + quads[i + 2].y)
            let lr = CGPoint(x: bounds.minX + quads[i + 3].x, y: bounds.minY + quads[i + 3].y)
            drawSquiggle(from: ll, to: lr, in: context)
            i += 4
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawSquiggle(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        let amplitude: CGFloat = 1.6
        let wavelength: CGFloat = 4.0
        let dx = end.x - start.x
        let length = abs(dx)
        guard length > 0 else { return }
        context.move(to: start)
        var x: CGFloat = 0
        var up = true
        while x < length {
            let next = min(x + wavelength / 2, length)
            let px = start.x + (dx < 0 ? -next : next)
            let py = start.y + (up ? amplitude : -amplitude)
            context.addLine(to: CGPoint(x: px, y: py))
            up.toggle()
            x = next
        }
    }
}

// MARK: - Polygon / Polyline

/// A closed polygon or open polyline. Vertices are page-space points packed
/// into `/Ream_Vertices`. Supports stroke color, fill (polygon only via
/// `interiorColor`), width, and opacity.
final class PolyShapeAnnotation: PDFAnnotation {
    /// Whether the path should be closed (polygon) or left open (polyline).
    var isClosed: Bool {
        (type ?? "") == "Polygon"
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        let verts = ReamGeometry.unpackPoints(stringValue(for: ReamAnnotationKey.vertices))
        guard verts.count >= 2 else { return }
        context.saveGState()
        let path = CGMutablePath()
        // Vertices are stored in page space; draw relative to page origin.
        path.move(to: verts[0])
        for p in verts.dropFirst() { path.addLine(to: p) }
        if isClosed { path.closeSubpath() }

        let lineWidth = border?.lineWidth ?? 1
        context.setLineWidth(max(lineWidth, 0.5))
        context.setLineJoin(.round)
        context.setLineCap(.round)

        if isClosed, let fill = interiorColor {
            context.addPath(path)
            context.setFillColor(fill.cgColor)
            context.fillPath()
        }
        context.addPath(path)
        context.setStrokeColor((color ?? .black).cgColor)
        context.strokePath()
        context.restoreGState()
    }
}

private extension PDFAnnotation {
    func stringValue(for key: PDFAnnotationKey) -> String? {
        value(forAnnotationKey: key) as? String
    }
}
