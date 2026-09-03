import Foundation

struct PDFDecodedGlyph {
    let code: Data
    let text: String
    let width: Double
    let isWordSpace: Bool
}

final class PDFFont {
    let resourceName: String
    let baseFont: String
    let subtype: String
    let isSubset: Bool
    let ascent: Double
    let descent: Double

    private let isComposite: Bool
    private let identityEncoding: Bool
    private let codeToCID: [Data: Int]
    private let unicodeByCode: [Data: String]
    private let simpleUnicodeByCode: [Int: String]
    private let widths: [Int: Double]
    private let defaultWidth: Double
    private let embeddedGlyphsByUnicode: [UInt32: Int]?
    private var usedCodes: Set<Data> = []

    init(resourceName: String, object: [String: PDFObject], document: PDFParsedDocument) throws {
        self.resourceName = resourceName
        self.baseFont = object["BaseFont"]?.nameValue ?? "Unknown"
        self.subtype = object["Subtype"]?.nameValue ?? "Unknown"
        self.isSubset = Self.isSubsetName(baseFont)
        self.isComposite = subtype == "Type0"

        let descriptor: [String: PDFObject]?
        let descendant: [String: PDFObject]?
        if isComposite,
           let descendants = try document.dereference(object["DescendantFonts"])?.arrayValue,
           let first = descendants.first {
            descendant = try document.dictionary(first)
            descriptor = try document.dictionary(descendant?["FontDescriptor"])
        } else {
            descendant = nil
            descriptor = try document.dictionary(object["FontDescriptor"])
        }
        self.ascent = descriptor?["Ascent"]?.doubleValue ?? 800
        self.descent = descriptor?["Descent"]?.doubleValue ?? -200
        let embeddedCMap = try Self.embeddedCMap(descriptor: descriptor, document: document)
        self.embeddedGlyphsByUnicode = embeddedCMap

        let toUnicode = try Self.readCMap(object["ToUnicode"], document: document)
        self.unicodeByCode = toUnicode.unicode

        if isComposite {
            let encodingName = object["Encoding"]?.nameValue
            identityEncoding = encodingName == "Identity-H" || encodingName == "Identity-V"
            if let encodingObject = object["Encoding"], encodingName == nil {
                codeToCID = try Self.readCMap(encodingObject, document: document).cid
            } else {
                codeToCID = [:]
            }
            let widthInfo = Self.compositeWidths(descendant ?? [:])
            widths = widthInfo.widths
            defaultWidth = widthInfo.defaultWidth
            simpleUnicodeByCode = [:]
        } else {
            identityEncoding = false
            codeToCID = [:]
            simpleUnicodeByCode = try Self.simpleEncoding(object: object, descriptor: descriptor,
                                                           embeddedCMap: embeddedCMap,
                                                           document: document)
            let widthInfo = try Self.simpleWidths(object: object, document: document,
                                                  baseFont: baseFont)
            widths = widthInfo.widths
            defaultWidth = widthInfo.defaultWidth
        }

    }

    func decode(_ bytes: Data) -> [PDFDecodedGlyph] {
        var output: [PDFDecodedGlyph] = []
        if isComposite {
            let lengths = Set(unicodeByCode.keys.map(\.count) + codeToCID.keys.map(\.count))
            let defaultLength = identityEncoding ? 2 : (lengths.max() ?? 2)
            var cursor = 0
            while cursor < bytes.count {
                var code: Data?
                for length in lengths.sorted(by: >) where cursor + length <= bytes.count {
                    let candidate = bytes.subdata(in: cursor..<(cursor + length))
                    if unicodeByCode[candidate] != nil || codeToCID[candidate] != nil { code = candidate; break }
                }
                let actual = code ?? bytes.subdata(in: cursor..<min(bytes.count, cursor + defaultLength))
                let cid = codeToCID[actual] ?? Self.bigEndianInt(actual)
                let text = unicodeByCode[actual] ?? UnicodeScalar(cid).map(String.init) ?? "\u{FFFD}"
                output.append(PDFDecodedGlyph(code: actual, text: text,
                                              width: widths[cid] ?? defaultWidth,
                                              isWordSpace: text == " "))
                usedCodes.insert(actual)
                cursor += actual.count
            }
        } else {
            for byte in bytes {
                let code = Data([byte])
                let text = unicodeByCode[code] ?? simpleUnicodeByCode[Int(byte)] ?? "\u{FFFD}"
                output.append(PDFDecodedGlyph(code: code, text: text,
                                              width: widths[Int(byte)] ?? defaultWidth,
                                              isWordSpace: byte == 32 || text == " "))
                usedCodes.insert(code)
            }
        }
        return output
    }

    func encode(_ string: String) -> (data: Data?, missing: [String]) {
        var inverse: [String: Data] = [:]
        for (code, text) in unicodeByCode { inverse[text] = inverse[text] ?? code }
        if !isComposite {
            for (code, text) in simpleUnicodeByCode { inverse[text] = inverse[text] ?? Data([UInt8(code)]) }
        }
        var output = Data()
        var missing: [String] = []
        for character in string {
            let text = String(character)
            guard let code = inverse[text], subsetAllows(text: text, code: code) else {
                if !missing.contains(text) { missing.append(text) }
                continue
            }
            output.append(code)
        }
        return (missing.isEmpty ? output : nil, missing)
    }

    private func subsetAllows(text: String, code: Data) -> Bool {
        guard isSubset else { return true }
        if let embeddedGlyphsByUnicode {
            return text.unicodeScalars.allSatisfy { (embeddedGlyphsByUnicode[$0.value] ?? 0) != 0 }
        }
        return usedCodes.contains(code)
    }

    private static func isSubsetName(_ name: String) -> Bool {
        let parts = name.split(separator: "+", maxSplits: 1)
        return parts.count == 2 && parts[0].count == 6
            && parts[0].allSatisfy { $0 >= "A" && $0 <= "Z" }
    }

    private static func readCMap(_ object: PDFObject?, document: PDFParsedDocument) throws
        -> (unicode: [Data: String], cid: [Data: Int]) {
        guard let stream = try document.stream(object) else { return ([:], [:]) }
        return PDFCMapParser.parse(try PDFStreamFilters.decode(stream))
    }

    private static func simpleEncoding(object: [String: PDFObject],
                                       descriptor: [String: PDFObject]?,
                                       embeddedCMap: [UInt32: Int]?,
                                       document: PDFParsedDocument) throws -> [Int: String] {
        let encodingObject = try document.dereference(object["Encoding"])
        let encodingDictionary = encodingObject?.dictionaryValue
        let baseName = encodingObject?.nameValue ?? encodingDictionary?["BaseEncoding"]?.nameValue
        let flags = descriptor?["Flags"]?.intValue ?? 0
        let isSymbolic = (flags & 4) != 0
        var mapping: [Int: String]
        if baseName == nil, isSymbolic, let embeddedCMap {
            mapping = symbolicEncoding(from: embeddedCMap)
        } else {
            mapping = baseEncoding(baseName ?? (isSymbolic ? "MacRomanEncoding" : "StandardEncoding"))
        }
        if let differences = try document.dereference(encodingDictionary?["Differences"])?.arrayValue {
            var code = 0
            for item in differences {
                if let start = item.intValue { code = start }
                else if let glyph = item.nameValue {
                    if let scalar = AdobeGlyphList.unicode(glyph) { mapping[code] = scalar }
                    code += 1
                }
            }
        }
        return mapping
    }

    /// Symbolic TrueType fonts commonly expose byte `c` in a Microsoft symbol
    /// cmap at U+F000+c (occasionally F100/F200), rather than through a named
    /// PDF encoding. Prefer a real Unicode cmap entry when one exists and then
    /// follow those symbol offsets so rendering, decoding and subset checks all
    /// refer to the same embedded glyph.
    private static func symbolicEncoding(from cmap: [UInt32: Int]) -> [Int: String] {
        var result: [Int: String] = [:]
        for code in 0...255 {
            let candidates = [UInt32(code), 0xF000 + UInt32(code),
                              0xF100 + UInt32(code), 0xF200 + UInt32(code)]
            guard let value = candidates.first(where: { (cmap[$0] ?? 0) != 0 }),
                  let scalar = UnicodeScalar(value) else { continue }
            result[code] = String(scalar)
        }
        return result
    }

    private static func baseEncoding(_ name: String) -> [Int: String] {
        if name == "StandardEncoding" {
            var result = Dictionary(uniqueKeysWithValues: (32...126).compactMap { code -> (Int, String)? in
                guard let scalar = UnicodeScalar(code) else { return nil }
                return (code, String(scalar))
            })
            // StandardEncoding entries above ASCII. Undefined slots stay
            // absent so the encoder cannot claim a glyph the PDF font lacks.
            let names: [Int: String] = [161: "¡", 162: "¢", 163: "£", 164: "⁄",
                165: "¥", 166: "ƒ", 167: "§", 168: "¤", 169: "'", 170: "“",
                171: "«", 172: "‹", 173: "›", 174: "ﬁ", 175: "ﬂ", 177: "–",
                178: "†", 179: "‡", 180: "·", 182: "¶", 183: "•", 184: "‚",
                185: "„", 186: "”", 187: "»", 188: "…", 189: "‰", 191: "¿",
                193: "`", 194: "´", 195: "ˆ", 196: "˜", 197: "¯", 198: "˘",
                199: "˙", 200: "¨", 202: "˚", 203: "¸", 205: "˝", 206: "˛", 207: "ˇ"]
            result.merge(names) { _, new in new }
            return result
        }
        let encoding: String.Encoding
        switch name {
        case "WinAnsiEncoding": encoding = .windowsCP1252
        case "MacRomanEncoding", "MacExpertEncoding": encoding = .macOSRoman
        default: encoding = .isoLatin1
        }
        var result: [Int: String] = [:]
        for code in 0...255 {
            if let string = String(data: Data([UInt8(code)]), encoding: encoding),
               !string.isEmpty, string.unicodeScalars.first?.value != 0 {
                result[code] = string
            }
        }
        return result
    }

    private static func simpleWidths(object: [String: PDFObject], document: PDFParsedDocument,
                                     baseFont: String) throws -> (widths: [Int: Double], defaultWidth: Double) {
        let first = object["FirstChar"]?.intValue ?? 0
        let values = try document.dereference(object["Widths"])?.arrayValue ?? []
        var result: [Int: Double] = [:]
        for (index, value) in values.enumerated() { if let width = value.doubleValue { result[first + index] = width } }
        let descriptor = try document.dictionary(object["FontDescriptor"])
        let missing = descriptor?["MissingWidth"]?.doubleValue ?? Standard14Widths.defaultWidth(baseFont)
        if result.isEmpty { result = Standard14Widths.widths(baseFont) }
        return (result, missing)
    }

    private static func compositeWidths(_ descendant: [String: PDFObject])
        -> (widths: [Int: Double], defaultWidth: Double) {
        let values = descendant["W"]?.arrayValue ?? []
        var output: [Int: Double] = [:]
        var cursor = 0
        while cursor < values.count {
            guard let first = values[cursor].intValue else { cursor += 1; continue }
            cursor += 1
            guard cursor < values.count else { break }
            if let array = values[cursor].arrayValue {
                for (offset, width) in array.enumerated() {
                    if let width = width.doubleValue { output[first + offset] = width }
                }
                cursor += 1
            } else if cursor + 1 < values.count,
                      let last = values[cursor].intValue,
                      let width = values[cursor + 1].doubleValue {
                if last >= first { for cid in first...last { output[cid] = width } }
                cursor += 2
            } else { cursor += 1 }
        }
        return (output, descendant["DW"]?.doubleValue ?? 1000)
    }

    private static func embeddedCMap(descriptor: [String: PDFObject]?, document: PDFParsedDocument) throws
        -> [UInt32: Int]? {
        guard let descriptor else { return nil }
        let file = descriptor["FontFile2"] ?? descriptor["FontFile3"]
        guard let stream = try document.stream(file) else { return nil }
        return TrueTypeCMap.parse(try PDFStreamFilters.decode(stream))
    }

    private static func bigEndianInt(_ data: Data) -> Int {
        data.reduce(0) { ($0 << 8) | Int($1) }
    }
}

private enum PDFCMapToken {
    case hex(Data), integer(Int), word(String), openArray, closeArray
}

private enum PDFCMapParser {
    static func parse(_ data: Data) -> (unicode: [Data: String], cid: [Data: Int]) {
        let tokens = tokenize(data)
        var unicode: [Data: String] = [:], cid: [Data: Int] = [:]
        var index = 0
        while index < tokens.count {
            guard case .integer(let count) = tokens[index], index + 1 < tokens.count,
                  case .word(let section) = tokens[index + 1] else { index += 1; continue }
            index += 2
            switch section {
            case "beginbfchar", "begincidchar":
                for _ in 0..<count where index + 1 < tokens.count {
                    guard case .hex(let source) = tokens[index] else { break }
                    if section == "beginbfchar", case .hex(let target) = tokens[index + 1] {
                        unicode[source] = unicodeString(target)
                    } else if section == "begincidchar" {
                        switch tokens[index + 1] {
                        case .integer(let target): cid[source] = target
                        case .hex(let target): cid[source] = bigEndian(target)
                        default: break
                        }
                    }
                    index += 2
                }
            case "beginbfrange", "begincidrange":
                for _ in 0..<count where index + 2 < tokens.count {
                    guard case .hex(let lowerData) = tokens[index],
                          case .hex(let upperData) = tokens[index + 1] else { break }
                    let lower = bigEndian(lowerData), upper = bigEndian(upperData)
                    index += 2
                    if section == "beginbfrange" {
                        if case .openArray = tokens[index] {
                            index += 1
                            var code = lower
                            while index < tokens.count, code <= upper {
                                if case .closeArray = tokens[index] { index += 1; break }
                                if case .hex(let target) = tokens[index] {
                                    unicode[makeData(code, width: lowerData.count)] = unicodeString(target)
                                }
                                code += 1; index += 1
                            }
                            while index < tokens.count {
                                if case .closeArray = tokens[index] { index += 1; break }
                                index += 1
                            }
                        } else if case .hex(let target) = tokens[index] {
                            let targetBase = bigEndian(target)
                            for code in lower...upper {
                                let destination = makeData(targetBase + code - lower, width: target.count)
                                unicode[makeData(code, width: lowerData.count)] = unicodeString(destination)
                            }
                            index += 1
                        }
                    } else {
                        let target: Int
                        switch tokens[index] {
                        case .integer(let value): target = value
                        case .hex(let value): target = bigEndian(value)
                        default: target = 0
                        }
                        for code in lower...upper { cid[makeData(code, width: lowerData.count)] = target + code - lower }
                        index += 1
                    }
                }
            default: break
            }
        }
        return (unicode, cid)
    }

    private static func tokenize(_ data: Data) -> [PDFCMapToken] {
        let bytes = Array(data)
        var result: [PDFCMapToken] = [], index = 0
        while index < bytes.count {
            if PDFSyntaxParser.isWhitespace(bytes[index]) { index += 1; continue }
            if bytes[index] == 0x25 { while index < bytes.count, bytes[index] != 0x0A { index += 1 }; continue }
            if bytes[index] == 0x5B { result.append(.openArray); index += 1; continue }
            if bytes[index] == 0x5D { result.append(.closeArray); index += 1; continue }
            if bytes[index] == 0x3C, index + 1 < bytes.count, bytes[index + 1] != 0x3C {
                var parser = PDFSyntaxParser(bytes: bytes, offset: index)
                if let value = try? parser.parseHexString() { result.append(.hex(value)); index = parser.index; continue }
            }
            let start = index
            while index < bytes.count, !PDFSyntaxParser.isWhitespace(bytes[index]),
                  ![0x5B, 0x5D, 0x3C, 0x3E].contains(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            if let value = Int(word) { result.append(.integer(value)) }
            else if !word.isEmpty { result.append(.word(word)) }
            else { index += 1 }
        }
        return result
    }

    private static func unicodeString(_ data: Data) -> String {
        if data.count % 2 == 0, !data.isEmpty {
            var units: [UInt16] = []
            for index in stride(from: 0, to: data.count, by: 2) {
                units.append(UInt16(data[index]) << 8 | UInt16(data[index + 1]))
            }
            return String(decoding: units, as: UTF16.self)
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func bigEndian(_ data: Data) -> Int { data.reduce(0) { ($0 << 8) | Int($1) } }

    private static func makeData(_ value: Int, width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }
}

private enum AdobeGlyphList {
    private static let names: [String: String] = [
        "space":" ", "exclam":"!", "quotedbl":"\"", "numbersign":"#", "dollar":"$",
        "percent":"%", "ampersand":"&", "quotesingle":"'", "parenleft":"(", "parenright":")",
        "asterisk":"*", "plus":"+", "comma":",", "hyphen":"-", "period":".", "slash":"/",
        "colon":":", "semicolon":";", "less":"<", "equal":"=", "greater":">", "question":"?",
        "at":"@", "bracketleft":"[", "backslash":"\\", "bracketright":"]", "asciicircum":"^",
        "underscore":"_", "grave":"`", "braceleft":"{", "bar":"|", "braceright":"}", "asciitilde":"~",
        "Euro":"€", "bullet":"•", "endash":"–", "emdash":"—", "quotedblleft":"“",
        "quotedblright":"”", "quoteleft":"‘", "quoteright":"’", "ellipsis":"…", "fi":"ﬁ", "fl":"ﬂ"
    ]

    static func unicode(_ rawName: String) -> String? {
        let name = rawName.split(separator: ".").first.map(String.init) ?? rawName
        if name.count == 1 { return name }
        if let known = names[name] { return known }
        if name.hasPrefix("uni"), name.count >= 7 {
            let hex = String(name.dropFirst(3))
            var output = ""
            for index in stride(from: 0, to: hex.count, by: 4) {
                let start = hex.index(hex.startIndex, offsetBy: index)
                let end = hex.index(start, offsetBy: min(4, hex.count - index))
                if let value = UInt32(hex[start..<end], radix: 16), let scalar = UnicodeScalar(value) { output.append(Character(scalar)) }
            }
            return output.isEmpty ? nil : output
        }
        if name.hasPrefix("u"), let value = UInt32(name.dropFirst(), radix: 16), let scalar = UnicodeScalar(value) {
            return String(scalar)
        }
        if name.count == 1 { return name }
        // Letter and digit glyph names are their own Unicode spelling.
        if name.count == 1 || (name.count == 2 && name.first == "A") { return name }
        let digitNames = ["zero","one","two","three","four","five","six","seven","eight","nine"]
        if let index = digitNames.firstIndex(of: name) { return String(index) }
        return nil
    }
}

private enum Standard14Widths {
    static func defaultWidth(_ name: String) -> Double {
        normalized(name).hasPrefix("Courier") ? 600 : 500
    }

    static func widths(_ name: String) -> [Int: Double] {
        if normalized(name).hasPrefix("Courier") { return Dictionary(uniqueKeysWithValues: (0...255).map { ($0, 600) }) }
        let isTimes = normalized(name).hasPrefix("Times")
        let values = isTimes ? times : helvetica
        var output: [Int: Double] = [:]
        for (offset, width) in values.enumerated() { output[32 + offset] = Double(width) }
        return output
    }

    private static func normalized(_ name: String) -> String {
        name.split(separator: "+", maxSplits: 1).last.map(String.init) ?? name
    }

    // ASCII 32...126, bundled from the standard AFM metrics. Bold/italic faces
    // have small differences; these base metrics remain preferable to guessing.
    private static let helvetica = [278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,
        556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,
        778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,
        469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,
        556,500,722,500,500,500,334,260,334,584]
    private static let times = [250,333,408,500,500,833,778,180,333,333,500,564,250,333,250,278,
        500,500,500,500,500,500,500,500,500,500,278,278,564,564,564,444,921,722,667,667,722,611,556,
        722,722,333,389,722,611,889,722,722,556,722,667,556,611,722,722,944,722,722,611,333,278,333,
        469,500,333,444,500,444,500,444,333,500,500,278,278,500,278,778,500,500,500,500,333,389,278,
        500,500,722,500,500,444,480,200,480,541]
}

private enum TrueTypeCMap {
    static func parse(_ data: Data) -> [UInt32: Int]? {
        let bytes = Array(data)
        guard bytes.count >= 12 else { return nil }
        let signature = read32(bytes, 0)
        let tableBase: Int
        if signature == 0x00010000 || signature == 0x4F54544F || signature == 0x74727565 {
            let count = read16(bytes, 4)
            var cmapOffset: Int?
            for index in 0..<count {
                let record = 12 + index * 16
                guard record + 16 <= bytes.count else { break }
                if String(decoding: bytes[record..<(record + 4)], as: UTF8.self) == "cmap" {
                    cmapOffset = read32(bytes, record + 8); break
                }
            }
            guard let cmapOffset else { return nil }
            tableBase = cmapOffset
        } else { tableBase = 0 }
        guard tableBase + 4 <= bytes.count else { return nil }
        let count = read16(bytes, tableBase + 2)
        var candidates: [(Int, Int)] = []
        for index in 0..<count {
            let record = tableBase + 4 + index * 8
            guard record + 8 <= bytes.count else { break }
            let platform = read16(bytes, record), encoding = read16(bytes, record + 2)
            let offset = tableBase + read32(bytes, record + 4)
            let priority = platform == 3 && encoding == 10 ? 0 : (platform == 0 ? 1 : 2)
            candidates.append((priority, offset))
        }
        for (_, offset) in candidates.sorted(by: { $0.0 < $1.0 }) {
            guard offset + 2 <= bytes.count else { continue }
            switch read16(bytes, offset) {
            case 12: if let result = format12(bytes, offset), !result.isEmpty { return result }
            case 4: if let result = format4(bytes, offset), !result.isEmpty { return result }
            default: continue
            }
        }
        return nil
    }

    private static func format12(_ b: [UInt8], _ o: Int) -> [UInt32: Int]? {
        guard o + 16 <= b.count else { return nil }
        let groups = read32(b, o + 12)
        var result: [UInt32: Int] = [:]
        for index in 0..<groups {
            let p = o + 16 + index * 12
            guard p + 12 <= b.count else { return nil }
            let start = UInt32(read32(b, p)), end = UInt32(read32(b, p + 4)), glyph = read32(b, p + 8)
            guard end >= start, end - start < 1_000_000 else { continue }
            for value in start...end { result[value] = glyph + Int(value - start) }
        }
        return result
    }

    private static func format4(_ b: [UInt8], _ o: Int) -> [UInt32: Int]? {
        guard o + 14 <= b.count else { return nil }
        let length = read16(b, o + 2), segments = read16(b, o + 6) / 2
        guard o + length <= b.count, segments > 0 else { return nil }
        let endBase = o + 14, startBase = endBase + segments * 2 + 2
        let deltaBase = startBase + segments * 2, rangeBase = deltaBase + segments * 2
        var result: [UInt32: Int] = [:]
        for segment in 0..<segments {
            let end = read16(b, endBase + segment * 2), start = read16(b, startBase + segment * 2)
            let delta = read16(b, deltaBase + segment * 2), range = read16(b, rangeBase + segment * 2)
            guard end >= start, end != 0xFFFF else { continue }
            for code in start...end {
                let glyph: Int
                if range == 0 { glyph = (code + delta) & 0xFFFF }
                else {
                    let address = rangeBase + segment * 2 + range + (code - start) * 2
                    guard address + 2 <= o + length else { continue }
                    let raw = read16(b, address)
                    glyph = raw == 0 ? 0 : (raw + delta) & 0xFFFF
                }
                result[UInt32(code)] = glyph
            }
        }
        return result
    }

    private static func read16(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 2 <= b.count else { return 0 }
        return Int(b[o]) << 8 | Int(b[o + 1])
    }
    private static func read32(_ b: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
}
