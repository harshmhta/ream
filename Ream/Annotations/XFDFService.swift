import PDFKit
import AppKit

/// Reads and writes XFDF (XML Forms Data Format) — the interchange format
/// Acrobat and other tools use to move annotations between copies of a
/// document. PDFKit has **no** XFDF API, so Ream implements the codec directly.
///
/// Coordinate model: XFDF, like PDF, uses page space with a bottom-left origin,
/// so no axis flipping is needed. `rect` is `xmin,ymin,xmax,ymax`; markup
/// `coords` are QuadPoints (absolute page space); `inklist`/`vertices` are
/// `x,y` pairs separated by `;`. Ream's own identity/threading/resolve state
/// travels in `ream*` attributes that other readers harmlessly ignore.
enum XFDFService {

    enum XFDFError: LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let why): return "Could not read XFDF: \(why)"
            }
        }
    }

    // MARK: - Export

    /// Serialize every listable annotation in `document` to XFDF data.
    static func export(_ document: PDFDocument) -> Data {
        let root = XMLElement(name: "xfdf")
        root.addAttribute(xmlAttribute(name: "xmlns", value: "http://ns.adobe.com/xfdf/"))
        root.addAttribute(xmlAttribute(name: "xml:space", value: "preserve"))
        let annots = XMLElement(name: "annots")
        root.addChild(annots)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations where annotation.isReamListable {
                if let element = element(for: annotation, pageIndex: pageIndex) {
                    annots.addChild(element)
                }
            }
        }

        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        return doc.xmlData(options: [.nodePrettyPrint])
    }

    private static func element(for annotation: PDFAnnotation, pageIndex: Int) -> XMLElement? {
        guard let subtype = annotation.type else { return nil }
        let name = xfdfName(forSubtype: subtype)
        let element = XMLElement(name: name)
        let bounds = annotation.bounds

        element.addAttribute(xmlAttribute(name: "page", value: String(pageIndex)))
        element.addAttribute(xmlAttribute(name: "rect", value: rectString(bounds)))
        let color = annotation.color
        if color != .clear, color.alphaComponent > 0 {
            element.addAttribute(xmlAttribute(name: "color", value: hexString(color)))
        }
        if let title = annotation.userName {
            element.addAttribute(xmlAttribute(name: "title", value: title))
        }
        if let date = annotation.modificationDate {
            element.addAttribute(xmlAttribute(name: "date", value: pdfDateString(date)))
        }
        // Ream metadata (ignored by other readers, restores threading on import).
        element.addAttribute(xmlAttribute(name: "name", value: annotation.reamID))
        if let irt = annotation.reamInReplyTo {
            element.addAttribute(xmlAttribute(name: "inreplyto", value: irt))
        }
        if annotation.reamResolved {
            element.addAttribute(xmlAttribute(name: "reamresolved", value: "true"))
        }
        if let opacity = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/CA")) as? NSNumber {
            element.addAttribute(xmlAttribute(name: "opacity", value: String(opacity.doubleValue)))
        }
        if let width = annotation.border?.lineWidth, width > 0 {
            element.addAttribute(xmlAttribute(name: "width", value: String(Double(width))))
        }
        if let interior = annotation.interiorColor {
            element.addAttribute(xmlAttribute(name: "interior-color", value: hexString(interior)))
        }

        // Contents as a child element (may contain arbitrary text).
        if let contents = annotation.contents, !contents.isEmpty {
            let c = XMLElement(name: "contents", stringValue: contents)
            element.addChild(c)
        }

        // Type-specific geometry.
        switch subtype {
        case "Highlight", "Underline", "StrikeOut":
            if let coords = coordsString(from: annotation) {
                element.addAttribute(xmlAttribute(name: "coords", value: coords))
            }
        case "Squiggly":
            // Ream-drawn markup: quads live in /Ream_Vertices (relative to
            // bounds). Re-emit as absolute coords for interop + round-trip.
            if let coords = coordsFromVertices(annotation) {
                element.addAttribute(xmlAttribute(name: "coords", value: coords))
            }
        case "Ink":
            if let inklist = inklistElement(from: annotation) {
                element.addChild(inklist)
            }
        case "Line":
            let a = annotation.startPoint, b = annotation.endPoint
            element.addAttribute(xmlAttribute(name: "start", value: "\(fmt(a.x)),\(fmt(a.y))"))
            element.addAttribute(xmlAttribute(name: "end", value: "\(fmt(b.x)),\(fmt(b.y))"))
            let head = PDFAnnotation.name(for: annotation.startLineStyle)
            let tail = PDFAnnotation.name(for: annotation.endLineStyle)
            element.addAttribute(xmlAttribute(name: "head", value: head))
            element.addAttribute(xmlAttribute(name: "tail", value: tail))
        case "Polygon", "PolyLine":
            if let verts = annotation.value(forAnnotationKey: ReamAnnotationKey.vertices) as? String {
                let element2 = XMLElement(name: "vertices", stringValue: verticesString(verts))
                element.addChild(element2)
            }
        case "Stamp":
            if let stampName = annotation.stampName {
                element.addAttribute(xmlAttribute(name: "icon", value: stampName))
            }
        default:
            break
        }
        return element
    }

    // MARK: - Import

    /// Parse XFDF `data` and add the reconstructed annotations to `document`,
    /// returning the number added. Existing annotations are left untouched.
    @discardableResult
    static func `import`(_ data: Data, into document: PDFDocument) throws -> Int {
        let xml: XMLDocument
        do {
            xml = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw XFDFError.malformed(error.localizedDescription)
        }
        guard let root = xml.rootElement() else {
            throw XFDFError.malformed("no root element")
        }
        // <annots> may be a direct child of <xfdf>.
        let annotsNodes = (try? root.nodes(forXPath: "//*[local-name()='annots']")) ?? []
        let annots = (annotsNodes.first as? XMLElement) ?? root

        var added = 0
        for case let element as XMLElement in annots.children ?? [] {
            guard let annotation = makeAnnotation(from: element, in: document) else { continue }
            let pageIndex = intAttr(element, "page") ?? 0
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { continue }
            page.addAnnotation(annotation)
            added += 1
        }
        return added
    }

    private static func makeAnnotation(from element: XMLElement, in document: PDFDocument) -> PDFAnnotation? {
        let tag = element.name?.lowercased() ?? ""
        guard let rect = rectAttr(element, "rect") else { return nil }

        let annotation: PDFAnnotation
        switch tag {
        case "highlight", "underline", "strikeout":
            let subtype: PDFAnnotationSubtype = tag == "underline" ? .underline
                : tag == "strikeout" ? .strikeOut : .highlight
            annotation = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
            if let coords = element.attribute(forName: "coords")?.stringValue {
                annotation.quadrilateralPoints = quadValues(from: coords, boundsOrigin: rect.origin)
            }
        case "squiggly":
            let a = SquigglyAnnotation(bounds: rect,
                                       forType: PDFAnnotationSubtype(rawValue: "Squiggly"),
                                       withProperties: nil)
            a.setValue("Squiggly", forAnnotationKey: PDFAnnotationKey(rawValue: "/Subtype"))
            if let coords = element.attribute(forName: "coords")?.stringValue {
                a.setValue(packedRelativeQuads(from: coords, origin: rect.origin),
                          forAnnotationKey: ReamAnnotationKey.vertices)
            }
            annotation = a
        case "text":
            annotation = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
        case "ink":
            annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            for path in inkPaths(from: element) where path.count >= 2 {
                let bezier = NSBezierPath()
                bezier.move(to: path[0])
                for p in path.dropFirst() { bezier.line(to: p) }
                annotation.add(bezier)
            }
        case "square":
            annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        case "circle":
            annotation = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
        case "line":
            annotation = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
            if let s = pointAttr(element, "start") { annotation.startPoint = s }
            if let e = pointAttr(element, "end") { annotation.endPoint = e }
            if let head = element.attribute(forName: "head")?.stringValue {
                annotation.startLineStyle = PDFAnnotation.lineStyle(fromName: head)
            }
            if let tail = element.attribute(forName: "tail")?.stringValue {
                annotation.endLineStyle = PDFAnnotation.lineStyle(fromName: tail)
            }
        case "polygon", "polyline":
            let subtype = tag == "polygon" ? "Polygon" : "PolyLine"
            let a = PolyShapeAnnotation(bounds: rect,
                                        forType: PDFAnnotationSubtype(rawValue: subtype),
                                        withProperties: nil)
            a.setValue(subtype, forAnnotationKey: PDFAnnotationKey(rawValue: "/Subtype"))
            if let vertsText = childText(element, "vertices") {
                a.setValue(packPointsFromSemicolon(vertsText), forAnnotationKey: ReamAnnotationKey.vertices)
            }
            annotation = a
        case "freetext":
            annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.font = NSFont.systemFont(ofSize: 14)
            annotation.color = .clear
        case "stamp":
            annotation = PDFAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
            if let icon = element.attribute(forName: "icon")?.stringValue {
                annotation.stampName = icon
            }
        default:
            return nil
        }

        // Common attributes.
        if let colorHex = element.attribute(forName: "color")?.stringValue,
           let color = color(fromHex: colorHex) {
            annotation.color = color
        }
        if let interiorHex = element.attribute(forName: "interior-color")?.stringValue,
           let color = color(fromHex: interiorHex) {
            annotation.interiorColor = color
        }
        if let widthStr = element.attribute(forName: "width")?.stringValue, let width = Double(widthStr) {
            let border = PDFBorder(); border.lineWidth = CGFloat(width); annotation.border = border
        }
        if let opacityStr = element.attribute(forName: "opacity")?.stringValue, let opacity = Double(opacityStr) {
            AnnotationFactory.applyOpacity(CGFloat(opacity), to: annotation)
        }
        if let contents = childText(element, "contents") {
            annotation.contents = contents
        }
        annotation.userName = element.attribute(forName: "title")?.stringValue ?? NSFullUserName()
        if let dateStr = element.attribute(forName: "date")?.stringValue, let date = pdfDate(from: dateStr) {
            annotation.modificationDate = date
        } else {
            annotation.modificationDate = Date()
        }
        // Restore Ream identity/threading/resolve.
        if let name = element.attribute(forName: "name")?.stringValue, !name.isEmpty {
            annotation.setValue(name, forAnnotationKey: ReamAnnotationKey.id)
        } else {
            _ = annotation.reamID
        }
        if let irt = element.attribute(forName: "inreplyto")?.stringValue {
            annotation.reamInReplyTo = irt
        }
        if element.attribute(forName: "reamresolved")?.stringValue == "true" {
            annotation.reamResolved = true
        }
        return annotation
    }

    // MARK: - Geometry / attribute helpers

    private static func xfdfName(forSubtype subtype: String) -> String {
        switch subtype {
        case "StrikeOut": return "strikeout"
        case "PolyLine": return "polyline"
        case "FreeText": return "freetext"
        default: return subtype.lowercased()
        }
    }

    private static func coordsString(from annotation: PDFAnnotation) -> String? {
        guard let quads = annotation.quadrilateralPoints, !quads.isEmpty else { return nil }
        let origin = annotation.bounds.origin
        let parts = quads.map { value -> String in
            let p = value.pointValue
            return "\(fmt(origin.x + p.x)),\(fmt(origin.y + p.y))"
        }
        return parts.joined(separator: ",")
    }

    private static func coordsFromVertices(_ annotation: PDFAnnotation) -> String? {
        guard let packed = annotation.value(forAnnotationKey: ReamAnnotationKey.vertices) as? String else { return nil }
        let rel = ReamGeometry.unpackPoints(packed)
        guard !rel.isEmpty else { return nil }
        let origin = annotation.bounds.origin
        return rel.map { "\(fmt(origin.x + $0.x)),\(fmt(origin.y + $0.y))" }.joined(separator: ",")
    }

    /// Convert an XFDF coords string (absolute page points) into PDFKit quad
    /// points relative to the annotation bounds origin.
    private static func quadValues(from coords: String, boundsOrigin: CGPoint) -> [NSValue] {
        let points = parsePairs(coords)
        return points.map { NSValue(point: CGPoint(x: $0.x - boundsOrigin.x, y: $0.y - boundsOrigin.y)) }
    }

    private static func packedRelativeQuads(from coords: String, origin: CGPoint) -> String {
        let rel = parsePairs(coords).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        return ReamGeometry.packPoints(rel)
    }

    private static func inklistElement(from annotation: PDFAnnotation) -> XMLElement? {
        guard let paths = annotation.paths, !paths.isEmpty else { return nil }
        let origin = annotation.bounds.origin
        let inklist = XMLElement(name: "inklist")
        for path in paths {
            let pts = bezierPoints(path)
            guard !pts.isEmpty else { continue }
            let text = pts.map { "\(fmt(origin.x + $0.x)),\(fmt(origin.y + $0.y))" }.joined(separator: ";")
            inklist.addChild(XMLElement(name: "gesture", stringValue: text))
        }
        return inklist.childCount > 0 ? inklist : nil
    }

    private static func inkPaths(from element: XMLElement) -> [[CGPoint]] {
        guard let inklist = (element.elements(forName: "inklist").first) else { return [] }
        return inklist.elements(forName: "gesture").compactMap { gesture in
            guard let text = gesture.stringValue else { return nil }
            let pts = text.split(separator: ";").compactMap { pair -> CGPoint? in
                let nums = pair.split(separator: ",").compactMap { Double($0) }
                guard nums.count == 2 else { return nil }
                return CGPoint(x: nums[0], y: nums[1])
            }
            return pts.isEmpty ? nil : pts
        }
    }

    private static func verticesString(_ packed: String) -> String {
        // /Ream_Vertices is "x,y,x,y…"; XFDF <vertices> uses "x,y;x,y…".
        let points = ReamGeometry.unpackPoints(packed)
        return points.map { "\(fmt($0.x)),\(fmt($0.y))" }.joined(separator: ";")
    }

    private static func packPointsFromSemicolon(_ text: String) -> String {
        let points = text.split(separator: ";").compactMap { pair -> CGPoint? in
            let nums = pair.split(separator: ",").compactMap { Double($0) }
            guard nums.count == 2 else { return nil }
            return CGPoint(x: nums[0], y: nums[1])
        }
        return ReamGeometry.packPoints(points)
    }

    private static func parsePairs(_ csv: String) -> [CGPoint] {
        let nums = csv.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        var points: [CGPoint] = []
        var i = 0
        while i + 1 < nums.count { points.append(CGPoint(x: nums[i], y: nums[i + 1])); i += 2 }
        return points
    }

    private static func bezierPoints(_ path: NSBezierPath) -> [CGPoint] {
        var points: [CGPoint] = []
        var raw = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<path.elementCount {
            let type = path.element(at: i, associatedPoints: &raw)
            switch type {
            case .moveTo, .lineTo: points.append(raw[0])
            case .curveTo: points.append(raw[2])
            case .closePath: break
            @unknown default: break
            }
        }
        return points
    }

    // MARK: XML / scalar helpers

    private static func xmlAttribute(name: String, value: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    }

    private static func rectString(_ r: CGRect) -> String {
        "\(fmt(r.minX)),\(fmt(r.minY)),\(fmt(r.maxX)),\(fmt(r.maxY))"
    }

    private static func rectAttr(_ element: XMLElement, _ name: String) -> CGRect? {
        guard let str = element.attribute(forName: name)?.stringValue else { return nil }
        let n = str.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    private static func pointAttr(_ element: XMLElement, _ name: String) -> CGPoint? {
        guard let str = element.attribute(forName: name)?.stringValue else { return nil }
        let n = str.split(separator: ",").compactMap { Double($0) }
        guard n.count == 2 else { return nil }
        return CGPoint(x: n[0], y: n[1])
    }

    private static func intAttr(_ element: XMLElement, _ name: String) -> Int? {
        guard let str = element.attribute(forName: name)?.stringValue else { return nil }
        return Int(str)
    }

    private static func childText(_ element: XMLElement, _ name: String) -> String? {
        element.elements(forName: name).first?.stringValue
    }

    private static func fmt(_ v: CGFloat) -> String { ReamGeometry.fmt(v) }

    private static func hexString(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func color(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func pdfDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'D:'yyyyMMddHHmmss"
        return f.string(from: date)
    }

    private static func pdfDate(from string: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'D:'yyyyMMddHHmmss"
        var s = string
        // Trim any trailing timezone tokens PDF dates may carry.
        if s.count > 16 { s = String(s.prefix(16)) }
        return f.date(from: s)
    }
}
