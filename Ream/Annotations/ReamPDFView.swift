import PDFKit
import AppKit

/// A `PDFView` subclass that adds annotation authoring on top of PDFKit's
/// built-in rendering, selection, and scrolling.
///
/// Interaction model, by tool:
/// - `.select`  → PDFKit's own text selection + click an annotation to select it.
/// - markup     → the user selects text normally; committing the tool applies
///                markup to the current selection (handled in the controller,
///                but we also apply on mouse-up so a drag-select feels direct).
/// - `.note`    → click drops a sticky note.
/// - `.ink`     → drag paints a stroke; `NSEvent.pressure` modulates width.
/// - `.eraser`  → drag removes ink strokes it touches.
/// - drag shapes (rect/ellipse/line/arrow/freeText/callout) → drag a rubber-band.
/// - vertex shapes (polygon/polyline) → click to add vertices, double-click /
///                Return to finish.
///
/// A transparent live-preview is drawn on top while dragging so the user sees
/// the shape before it is committed as a real `PDFAnnotation`.
final class ReamPDFView: PDFView {

    /// Set by the SwiftUI wrapper. All authoring routes through the controller
    /// so undo/inspector/save stay consistent.
    weak var annotationController: AnnotationController?

    // Drag state.
    private var dragOrigin: CGPoint?          // page space
    private var dragCurrent: CGPoint?         // page space
    private var dragPage: PDFPage?
    private var inkPoints: [CGPoint] = []      // page space, current stroke
    private var inkWidths: [CGFloat] = []      // matched to inkPoints (pressure)
    private var vertexPoints: [CGPoint] = []   // page space, polygon/polyline
    private var previewLayerNeedsClear = false

    private var tool: AnnotationTool { annotationController?.tool ?? .select }

    // MARK: Event routing

    override func mouseDown(with event: NSEvent) {
        guard let controller = annotationController else { super.mouseDown(with: event); return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event); return
        }
        let pagePoint = convert(viewPoint, to: page)

        switch tool {
        case .select:
            hitTestSelectOrDefer(event: event, page: page, pagePoint: pagePoint)
        case .highlight, .underline, .strikethrough, .squiggly:
            // Let PDFKit run its text selection; markup is applied on mouseUp.
            super.mouseDown(with: event)
        case .note:
            dropNote(at: pagePoint, on: page)
        case .ink:
            dragPage = page
            inkPoints = [pagePoint]
            inkWidths = [width(for: event)]
        case .eraser:
            dragPage = page
            eraseInk(at: pagePoint, on: page)
        case .rectangle, .ellipse, .line, .arrow, .freeText, .callout:
            dragPage = page
            dragOrigin = pagePoint
            dragCurrent = pagePoint
        case .polygon, .polyline:
            handleVertexClick(event: event, page: page, pagePoint: pagePoint)
        case .stamp:
            // Stamp placement is handled by the stamp picker → placePendingStamp.
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard annotationController != nil else { super.mouseDragged(with: event); return }
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch tool {
        case .ink:
            guard let page = dragPage else { break }
            let pagePoint = convert(viewPoint, to: page)
            inkPoints.append(pagePoint)
            inkWidths.append(width(for: event))
            setNeedsDisplay(bounds)
        case .eraser:
            guard let page = dragPage else { break }
            eraseInk(at: convert(viewPoint, to: page), on: page)
        case .rectangle, .ellipse, .line, .arrow, .freeText, .callout:
            guard let page = dragPage else { break }
            dragCurrent = convert(viewPoint, to: page)
            setNeedsDisplay(bounds)
        case .select, .highlight, .underline, .strikethrough, .squiggly:
            super.mouseDragged(with: event)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller = annotationController else { super.mouseUp(with: event); return }

        switch tool {
        case .highlight, .underline, .strikethrough, .squiggly:
            super.mouseUp(with: event)
            _ = controller.applyMarkupToSelection(tool, color: controller.style.color)
        case .ink:
            commitInk()
        case .eraser:
            dragPage = nil
        case .rectangle, .ellipse, .line, .arrow, .freeText, .callout:
            commitDragShape()
        case .select:
            super.mouseUp(with: event)
        default:
            super.mouseUp(with: event)
        }
    }

    // MARK: Select tool

    private func hitTestSelectOrDefer(event: NSEvent, page: PDFPage, pagePoint: CGPoint) {
        // Topmost annotation under the point wins.
        if let hit = page.annotations.reversed().first(where: {
            $0.isReamListable && $0.bounds.contains(pagePoint)
        }) {
            annotationController?.selectedAnnotation = hit
            // Double-click a note / free-text opens its editor.
            if event.clickCount >= 2, hit.type == "Text" || hit.type == "FreeText" {
                annotationController?.editingAnnotation = hit
            }
        } else {
            annotationController?.selectedAnnotation = nil
            super.mouseDown(with: event)   // fall back to text selection
        }
    }

    // MARK: Note

    private func dropNote(at point: CGPoint, on page: PDFPage) {
        let note = AnnotationFactory.note(at: point)
        annotationController?.add(note, to: page)
        annotationController?.selectedAnnotation = note
        annotationController?.editingAnnotation = note   // open editor immediately
        annotationController?.tool = .select
    }

    // MARK: Ink

    private func width(for event: NSEvent) -> CGFloat {
        let base = annotationController?.style.lineWidth ?? 2
        // NSEvent.pressure is 0…1 for pressure-capable devices, and defaults to
        // a sensible value otherwise; scale width around the base.
        let pressure = CGFloat(event.pressure)
        guard pressure > 0 else { return base }
        return base * (0.5 + pressure)
    }

    private func commitInk() {
        defer { inkPoints = []; inkWidths = []; dragPage = nil; setNeedsDisplay(bounds) }
        guard let page = dragPage, inkPoints.count >= 2,
              var style = annotationController?.style else { return }
        let smoothed = InkSmoothing.smooth(inkPoints, algorithm: .catmullRom)
        // Effective width = average of sampled pressures.
        if !inkWidths.isEmpty {
            style.lineWidth = inkWidths.reduce(0, +) / CGFloat(inkWidths.count)
        }
        if let ink = AnnotationFactory.ink(paths: [smoothed], style: style) {
            annotationController?.add(ink, to: page)
        }
    }

    // MARK: Eraser

    private func eraseInk(at point: CGPoint, on page: PDFPage) {
        let threshold: CGFloat = 8
        for annotation in page.annotations where annotation.type == "Ink" {
            guard let paths = annotation.paths else { continue }
            let origin = annotation.bounds.origin
            for path in paths {
                if bezierPasses(path, near: point, origin: origin, threshold: threshold) {
                    annotationController?.remove(annotation)
                    break
                }
            }
        }
    }

    private func bezierPasses(_ path: NSBezierPath, near point: CGPoint, origin: CGPoint, threshold: CGFloat) -> Bool {
        var raw = [NSPoint](repeating: .zero, count: 3)
        var last: CGPoint?
        for i in 0..<path.elementCount {
            let type = path.element(at: i, associatedPoints: &raw)
            let p = CGPoint(x: origin.x + raw[type == .curveTo ? 2 : 0].x,
                            y: origin.y + raw[type == .curveTo ? 2 : 0].y)
            if let last, ReamGeometry.distance(from: point, toSegment: last, p) <= threshold {
                return true
            }
            last = p
        }
        return false
    }

    // MARK: Drag shapes

    private func commitDragShape() {
        defer { dragOrigin = nil; dragCurrent = nil; dragPage = nil; setNeedsDisplay(bounds) }
        guard let page = dragPage, let origin = dragOrigin, let current = dragCurrent,
              let controller = annotationController else { return }
        let style = controller.style
        let rect = CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                          width: abs(current.x - origin.x), height: abs(current.y - origin.y))

        switch tool {
        case .rectangle, .ellipse:
            guard rect.width > 3, rect.height > 3 else { return }
            controller.add(controller.boxShapeAnnotation(tool, rect: rect), to: page)
        case .line, .arrow:
            guard hypot(current.x - origin.x, current.y - origin.y) > 3 else { return }
            controller.add(AnnotationFactory.lineShape(tool, from: origin, to: current, style: style), to: page)
        case .freeText:
            guard rect.width > 8, rect.height > 8 else { return }
            let annotation = AnnotationFactory.freeText(rect: rect, contents: "", style: style)
            controller.add(annotation, to: page)
            controller.selectedAnnotation = annotation
            controller.editingAnnotation = annotation
            controller.tool = .select
        case .callout:
            guard rect.width > 8, rect.height > 8 else { return }
            let annotation = AnnotationFactory.callout(rect: rect, anchor: origin, contents: "", style: style)
            controller.add(annotation, to: page)
            controller.selectedAnnotation = annotation
            controller.editingAnnotation = annotation
            controller.tool = .select
        default:
            break
        }
    }

    // MARK: Vertex shapes

    private func handleVertexClick(event: NSEvent, page: PDFPage, pagePoint: CGPoint) {
        if dragPage == nil { dragPage = page; vertexPoints = [] }
        guard dragPage === page else { return }   // stay on one page
        vertexPoints.append(pagePoint)
        if event.clickCount >= 2 { commitVertexShape() }
        setNeedsDisplay(bounds)
    }

    /// Finish the current polygon/polyline (called by double-click or Return).
    func commitVertexShape() {
        defer { vertexPoints = []; dragPage = nil; setNeedsDisplay(bounds) }
        guard let page = dragPage, vertexPoints.count >= 2,
              let controller = annotationController else { return }
        // Drop the duplicate final point produced by the finishing double-click.
        var points = vertexPoints
        if points.count > 2, let a = points.last, let b = points.dropLast().last,
           hypot(a.x - b.x, a.y - b.y) < 2 { points.removeLast() }
        if let annotation = AnnotationFactory.polyShape(tool, vertices: points, style: controller.style) {
            controller.add(annotation, to: page)
        }
        controller.tool = .select
    }

    override func keyDown(with event: NSEvent) {
        // Return finishes a vertex shape; Escape cancels an in-progress one.
        if tool.isVertexShape, !vertexPoints.isEmpty {
            if event.keyCode == 36 { commitVertexShape(); return }        // Return
            if event.keyCode == 53 { vertexPoints = []; dragPage = nil; setNeedsDisplay(bounds); return } // Esc
        }
        if event.keyCode == 51 || event.keyCode == 117 {   // Delete / Fwd-Delete
            if annotationController?.selectedAnnotation != nil {
                annotationController?.deleteSelected(); return
            }
        }
        super.keyDown(with: event)
    }

    /// Place a stamp the picker prepared, centered at the view's visible center
    /// (or the last click). Called by the stamp picker.
    func placeStamp(image: NSImage, name: String, size: CGSize) {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: page)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        let stamp = AnnotationFactory.stamp(image: image, at: rect, name: name)
        annotationController?.add(stamp, to: page)
        annotationController?.selectedAnnotation = stamp
    }

    // MARK: Live preview overlay

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let page = dragPage, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        let style = annotationController?.style ?? .init()
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineJoin(.round); context.setLineCap(.round)

        func toView(_ p: CGPoint) -> CGPoint { convert(p, from: page) }

        switch tool {
        case .ink where inkPoints.count >= 2:
            context.beginPath()
            context.move(to: toView(inkPoints[0]))
            for p in inkPoints.dropFirst() { context.addLine(to: toView(p)) }
            context.strokePath()
        case .rectangle, .ellipse:
            if let o = dragOrigin, let c = dragCurrent {
                let r = viewRect(from: o, to: c, page: page)
                if tool == .ellipse { context.strokeEllipse(in: r) } else { context.stroke(r) }
            }
        case .line, .arrow, .callout, .freeText:
            if let o = dragOrigin, let c = dragCurrent {
                if tool == .freeText { context.stroke(viewRect(from: o, to: c, page: page)) }
                else {
                    context.beginPath()
                    context.move(to: toView(o)); context.addLine(to: toView(c)); context.strokePath()
                }
            }
        case .polygon, .polyline:
            if vertexPoints.count >= 1 {
                context.beginPath()
                context.move(to: toView(vertexPoints[0]))
                for p in vertexPoints.dropFirst() { context.addLine(to: toView(p)) }
                context.strokePath()
                // Dots at vertices.
                for p in vertexPoints {
                    let v = toView(p)
                    context.fillEllipse(in: CGRect(x: v.x - 2, y: v.y - 2, width: 4, height: 4))
                }
            }
        default:
            break
        }
        context.restoreGState()
    }

    private func viewRect(from a: CGPoint, to b: CGPoint, page: PDFPage) -> CGRect {
        let va = convert(a, from: page), vb = convert(b, from: page)
        return CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                      width: abs(vb.x - va.x), height: abs(vb.y - va.y))
    }
}
