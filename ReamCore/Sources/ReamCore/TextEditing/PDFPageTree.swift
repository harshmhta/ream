import Foundation

/// A portable rectangle in PDF page coordinates.
public struct PDFTextRect: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    func union(_ other: PDFTextRect) -> PDFTextRect {
        let left = min(minX, other.minX), bottom = min(minY, other.minY)
        let right = max(maxX, other.maxX), top = max(maxY, other.maxY)
        return PDFTextRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

struct PDFPageInfo {
    let index: Int
    let reference: PDFObjectReference
    let dictionary: [String: PDFObject]
    let resources: [String: PDFObject]
    let mediaBox: PDFTextRect
    let cropBox: PDFTextRect
    let rotate: Int
    let contents: [PDFPageContent]

    func displayRect(for userRect: PDFTextRect) -> PDFTextRect {
        let points = [
            (userRect.minX, userRect.minY), (userRect.maxX, userRect.minY),
            (userRect.minX, userRect.maxY), (userRect.maxX, userRect.maxY)
        ].map(displayPoint)
        let xs = points.map(\.0), ys = points.map(\.1)
        return PDFTextRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0),
                           height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    private func displayPoint(_ point: (Double, Double)) -> (Double, Double) {
        let x = point.0 - cropBox.x, y = point.1 - cropBox.y
        switch rotate {
        case 90: return (y, cropBox.width - x)
        case 180: return (cropBox.width - x, cropBox.height - y)
        case 270: return (cropBox.height - y, x)
        default: return (x, y)
        }
    }
}

struct PDFPageContent {
    let arrayIndex: Int
    let reference: PDFObjectReference?
    let stream: PDFStream
}

extension PDFParsedDocument {
    func pages() throws -> [PDFPageInfo] {
        guard let root = try dictionary(trailer["Root"]), let pagesObject = root["Pages"] else {
            throw PDFObjectError.malformedObject(offset: 0, reason: "catalog has no page tree")
        }
        var output: [PDFPageInfo] = []
        try walkPages(pagesObject, inherited: [:], output: &output)
        return output
    }

    private func walkPages(_ object: PDFObject,
                           inherited: [String: PDFObject],
                           output: inout [PDFPageInfo]) throws {
        let reference = object.referenceValue
        guard let node = try dictionary(object) else { return }
        var attributes = inherited
        for key in ["Resources", "MediaBox", "CropBox", "Rotate"] {
            if let value = node[key] { attributes[key] = value }
        }
        if node["Type"]?.nameValue == "Page" || node["Kids"] == nil {
            guard let reference else {
                throw PDFObjectError.malformedObject(offset: 0, reason: "direct page objects cannot be incrementally edited")
            }
            let mediaBox = try rect(from: attributes["MediaBox"])
                ?? PDFTextRect(x: 0, y: 0, width: 612, height: 792)
            let cropBox = try rect(from: attributes["CropBox"]) ?? mediaBox
            let rotate = normalizedRotation(try dereference(attributes["Rotate"])?.intValue ?? 0)
            let resources = try dictionary(attributes["Resources"]) ?? [:]
            let contents = try pageContents(node["Contents"])
            output.append(PDFPageInfo(index: output.count, reference: reference,
                                      dictionary: node, resources: resources,
                                      mediaBox: mediaBox, cropBox: cropBox,
                                      rotate: rotate, contents: contents))
            return
        }
        let kids = try dereference(node["Kids"])?.arrayValue ?? []
        for child in kids { try walkPages(child, inherited: attributes, output: &output) }
    }

    private func pageContents(_ object: PDFObject?) throws -> [PDFPageContent] {
        guard let object else { return [] }
        let resolved = try dereference(object)
        let values = resolved?.arrayValue ?? [object]
        var output: [PDFPageContent] = []
        for (index, value) in values.enumerated() {
            guard let stream = try stream(value) else { continue }
            output.append(PDFPageContent(arrayIndex: index,
                                         reference: value.referenceValue,
                                         stream: stream))
        }
        return output
    }

    private func rect(from object: PDFObject?) throws -> PDFTextRect? {
        guard let values = try dereference(object)?.arrayValue, values.count >= 4 else { return nil }
        let numbers = try values.prefix(4).compactMap { try dereference($0)?.doubleValue }
        guard numbers.count == 4 else { return nil }
        return PDFTextRect(x: min(numbers[0], numbers[2]), y: min(numbers[1], numbers[3]),
                           width: abs(numbers[2] - numbers[0]), height: abs(numbers[3] - numbers[1]))
    }

    private func normalizedRotation(_ value: Int) -> Int {
        let result = value % 360
        return result < 0 ? result + 360 : result
    }
}
