import Foundation

/// One decoded glyph and its page-space bounds.
public struct PDFTextGlyph: Hashable, Sendable {
    public let text: String
    /// Unrotated PDF user-space bounds (the coordinate system PDFKit accepts).
    public let userSpaceBounds: PDFTextRect
    /// Crop/rotation-normalized displayed-page bounds.
    public let bounds: PDFTextRect
}

/// An independently editable string operand in a PDF text-showing operation.
/// A `TJ` array produces one run per string element so its numeric kerning and
/// neighboring strings remain byte-identical.
public struct PDFTextRun: Identifiable, Hashable, Sendable {
    public let id: String
    public let pageIndex: Int
    public let text: String
    /// Unrotated PDF user-space bounds, suitable for `PDFView.convert`.
    public let userSpaceBounds: PDFTextRect
    /// Crop/rotation-normalized bounds matching the displayed page.
    public let bounds: PDFTextRect
    public let glyphs: [PDFTextGlyph]
    public let fontName: String
    public let fontSize: Double
    public let operandByteRange: PDFByteRange
    public let operatorByteRange: PDFByteRange

    let contentIndex: Int
    let pageReference: PDFObjectReference
    let contentReference: PDFObjectReference?
    let fontKey: String
    let originalCodeBytes: Data
    let operandWasHex: Bool
}

private struct PDFMatrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    init(_ values: [Double] = [1, 0, 0, 1, 0, 0]) {
        if values.count >= 6 { a = values[0]; b = values[1]; c = values[2]; d = values[3]; e = values[4]; f = values[5] }
    }

    func multiplied(by rhs: PDFMatrix) -> PDFMatrix {
        PDFMatrix([a * rhs.a + c * rhs.b,
                   b * rhs.a + d * rhs.b,
                   a * rhs.c + c * rhs.d,
                   b * rhs.c + d * rhs.d,
                   a * rhs.e + c * rhs.f + e,
                   b * rhs.e + d * rhs.f + f])
    }

    func point(_ x: Double, _ y: Double) -> (Double, Double) {
        (a * x + c * y + e, b * x + d * y + f)
    }

    static func translation(_ x: Double, _ y: Double) -> PDFMatrix { PDFMatrix([1, 0, 0, 1, x, y]) }
}

private struct PDFTextState {
    var characterSpacing = 0.0
    var wordSpacing = 0.0
    var horizontalScale = 1.0
    var leading = 0.0
    var rise = 0.0
    var fontSize = 0.0
    var fontKey: String?
    var textMatrix = PDFMatrix()
    var lineMatrix = PDFMatrix()
    var ctm = PDFMatrix()
    var graphicsStack: [PDFMatrix] = []
}

final class PDFTextLayoutEngine {
    private let document: PDFParsedDocument
    private(set) var fonts: [String: PDFFont] = [:]
    private var runFonts: [String: PDFFont] = [:]

    init(document: PDFParsedDocument) { self.document = document }

    func font(forRunID id: String) -> PDFFont? { runFonts[id] }

    func runs(on page: PDFPageInfo) throws -> [PDFTextRun] {
        let pageFonts = try fonts(on: page)
        var state = PDFTextState()
        var runs: [PDFTextRun] = []
        for content in page.contents {
            let decoded = try PDFStreamFilters.decode(content.stream)
            let operations = try PDFContentTokenizer.operations(in: decoded)
            for operation in operations {
                try apply(operation, content: content, decoded: decoded,
                          page: page, pageFonts: pageFonts, state: &state, runs: &runs)
            }
        }
        return runs
    }

    private func fonts(on page: PDFPageInfo) throws -> [String: PDFFont] {
        guard let fontDictionary = try document.dictionary(page.resources["Font"]) else { return [:] }
        var result: [String: PDFFont] = [:]
        for (resourceName, object) in fontDictionary {
            guard let dictionary = try document.dictionary(object) else { continue }
            let identity = object.referenceValue.map { "\($0.objectNumber):\($0.generation)" }
                ?? "p\(page.index):\(resourceName)"
            if let cached = fonts[identity] { result[resourceName] = cached }
            else {
                let font = try PDFFont(resourceName: resourceName, object: dictionary, document: document)
                fonts[identity] = font
                result[resourceName] = font
            }
        }
        return result
    }

    private func apply(_ operation: PDFContentOperation,
                       content: PDFPageContent,
                       decoded: Data,
                       page: PDFPageInfo,
                       pageFonts: [String: PDFFont],
                       state: inout PDFTextState,
                       runs: inout [PDFTextRun]) throws {
        let numbers = operation.operands.compactMap { $0.object.doubleValue }
        switch operation.name {
        case "q": state.graphicsStack.append(state.ctm)
        case "Q": if let restored = state.graphicsStack.popLast() { state.ctm = restored }
        case "cm" where numbers.count >= 6:
            state.ctm = state.ctm.multiplied(by: PDFMatrix(Array(numbers.suffix(6))))
        case "BT": state.textMatrix = PDFMatrix(); state.lineMatrix = PDFMatrix()
        case "ET": break
        case "Tf" where operation.operands.count >= 2:
            state.fontKey = operation.operands[operation.operands.count - 2].object.nameValue
            state.fontSize = operation.operands.last?.object.doubleValue ?? 0
        case "Tc": if let value = numbers.last { state.characterSpacing = value }
        case "Tw": if let value = numbers.last { state.wordSpacing = value }
        case "Tz": if let value = numbers.last { state.horizontalScale = value / 100 }
        case "TL": if let value = numbers.last { state.leading = value }
        case "Ts": if let value = numbers.last { state.rise = value }
        case "Tm" where numbers.count >= 6:
            state.textMatrix = PDFMatrix(Array(numbers.suffix(6))); state.lineMatrix = state.textMatrix
        case "Td" where numbers.count >= 2:
            moveLine(numbers[numbers.count - 2], numbers[numbers.count - 1], state: &state)
        case "TD" where numbers.count >= 2:
            state.leading = -numbers[numbers.count - 1]
            moveLine(numbers[numbers.count - 2], numbers[numbers.count - 1], state: &state)
        case "T*": nextLine(state: &state)
        case "Tj":
            if let token = operation.operands.last?.strings.first {
                show(token, operation: operation, content: content, decoded: decoded,
                     page: page, fonts: pageFonts, state: &state, runs: &runs)
            }
        case "TJ":
            if let operand = operation.operands.last, case .array(let values) = operand.object {
                var stringIndex = 0
                for value in values {
                    if case .string = value, stringIndex < operand.strings.count {
                        show(operand.strings[stringIndex], operation: operation, content: content,
                             decoded: decoded, page: page, fonts: pageFonts, state: &state, runs: &runs)
                        stringIndex += 1
                    } else if let adjustment = value.doubleValue {
                        advance(-adjustment / 1000 * state.fontSize * state.horizontalScale, state: &state)
                    }
                }
            }
        case "'":
            nextLine(state: &state)
            if let token = operation.operands.last?.strings.first {
                show(token, operation: operation, content: content, decoded: decoded,
                     page: page, fonts: pageFonts, state: &state, runs: &runs)
            }
        case "\"":
            if operation.operands.count >= 3 {
                state.wordSpacing = operation.operands[operation.operands.count - 3].object.doubleValue ?? state.wordSpacing
                state.characterSpacing = operation.operands[operation.operands.count - 2].object.doubleValue ?? state.characterSpacing
            }
            nextLine(state: &state)
            if let token = operation.operands.last?.strings.first {
                show(token, operation: operation, content: content, decoded: decoded,
                     page: page, fonts: pageFonts, state: &state, runs: &runs)
            }
        default: break
        }
    }

    private func show(_ token: PDFContentStringToken,
                      operation: PDFContentOperation,
                      content: PDFPageContent,
                      decoded: Data,
                      page: PDFPageInfo,
                      fonts pageFonts: [String: PDFFont],
                      state: inout PDFTextState,
                      runs: inout [PDFTextRun]) {
        guard let fontKey = state.fontKey, let font = pageFonts[fontKey] else { return }
        let glyphs = font.decode(token.data)
        var publicGlyphs: [PDFTextGlyph] = []
        var runBounds: PDFTextRect?
        var rawRunBounds: PDFTextRect?
        for glyph in glyphs {
            let fontTransform = PDFMatrix([state.fontSize * state.horizontalScale, 0,
                                           0, state.fontSize, 0, state.rise])
            let transform = state.ctm.multiplied(by: state.textMatrix).multiplied(by: fontTransform)
            let raw = rect(transform: transform, x0: 0, y0: font.descent / 1000,
                           x1: glyph.width / 1000, y1: font.ascent / 1000)
            let displayed = page.displayRect(for: raw)
            publicGlyphs.append(PDFTextGlyph(text: glyph.text, userSpaceBounds: raw, bounds: displayed))
            runBounds = runBounds.map { $0.union(displayed) } ?? displayed
            rawRunBounds = rawRunBounds.map { $0.union(raw) } ?? raw
            let spacing = state.characterSpacing + (glyph.isWordSpace ? state.wordSpacing : 0)
            advance((glyph.width / 1000 * state.fontSize + spacing) * state.horizontalScale, state: &state)
        }
        let rawSyntaxFirst = token.range.lowerBound < decoded.count ? decoded[token.range.lowerBound] : 0
        let id = "\(page.index):\(content.arrayIndex):\(token.range.lowerBound):\(token.range.upperBound)"
        let emptyPoint = page.displayRect(for: PDFTextRect(x: state.textMatrix.e, y: state.textMatrix.f,
                                                           width: 0, height: state.fontSize))
        let emptyRaw = PDFTextRect(x: state.textMatrix.e, y: state.textMatrix.f,
                                   width: 0, height: state.fontSize)
        runs.append(PDFTextRun(id: id, pageIndex: page.index,
                               text: glyphs.map(\.text).joined(),
                               userSpaceBounds: rawRunBounds ?? emptyRaw,
                               bounds: runBounds ?? emptyPoint, glyphs: publicGlyphs,
                               fontName: font.baseFont, fontSize: state.fontSize,
                               operandByteRange: token.range,
                               operatorByteRange: operation.operatorRange,
                               contentIndex: content.arrayIndex,
                               pageReference: page.reference,
                               contentReference: content.reference,
                               fontKey: fontKey, originalCodeBytes: token.data,
                               operandWasHex: rawSyntaxFirst == 0x3C))
        runFonts[id] = font
    }

    private func moveLine(_ x: Double, _ y: Double, state: inout PDFTextState) {
        state.lineMatrix = state.lineMatrix.multiplied(by: .translation(x, y))
        state.textMatrix = state.lineMatrix
    }

    private func nextLine(state: inout PDFTextState) { moveLine(0, -state.leading, state: &state) }

    private func advance(_ x: Double, state: inout PDFTextState) {
        state.textMatrix = state.textMatrix.multiplied(by: .translation(x, 0))
    }

    private func rect(transform: PDFMatrix, x0: Double, y0: Double, x1: Double, y1: Double) -> PDFTextRect {
        let points = [transform.point(x0, y0), transform.point(x1, y0),
                      transform.point(x0, y1), transform.point(x1, y1)]
        let xs = points.map(\.0), ys = points.map(\.1)
        let left = xs.min() ?? 0, bottom = ys.min() ?? 0
        return PDFTextRect(x: left, y: bottom,
                           width: (xs.max() ?? left) - left,
                           height: (ys.max() ?? bottom) - bottom)
    }
}
