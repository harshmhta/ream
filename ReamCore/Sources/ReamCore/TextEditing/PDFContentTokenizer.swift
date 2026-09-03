import Foundation

struct PDFContentStringToken: Equatable {
    let data: Data
    let range: PDFByteRange
}

struct PDFContentToken {
    let object: PDFObject
    let range: PDFByteRange
    let strings: [PDFContentStringToken]
}

struct PDFContentOperation {
    let name: String
    let operands: [PDFContentToken]
    let operatorRange: PDFByteRange
}

/// Tokenizes a decoded content stream without normalizing it. Every token keeps
/// its original byte range so an edit can replace one string token and copy all
/// surrounding content byte-for-byte.
enum PDFContentTokenizer {
    static func operations(in data: Data) throws -> [PDFContentOperation] {
        let bytes = Array(data)
        var parser = PDFSyntaxParser(bytes: bytes)
        var operands: [PDFContentToken] = []
        var operations: [PDFContentOperation] = []

        while !parser.isAtEnd {
            parser.skipSpaceAndComments()
            guard !parser.isAtEnd else { break }
            let start = parser.index
            let byte = bytes[start]
            if beginsObject(byte, parser: parser) {
                guard let object = try? parser.parseObject() else {
                    parser.index = start + 1
                    operands.removeAll(keepingCapacity: true)
                    continue
                }
                let end = parser.index
                let strings = stringTokens(in: bytes, range: start..<end, root: object)
                operands.append(PDFContentToken(object: object,
                                                range: PDFByteRange(start, end),
                                                strings: strings))
                continue
            }

            let name = parser.parseRegularToken()
            guard !name.isEmpty else {
                // Compatibility with malformed-but-renderable content streams:
                // skip a stray delimiter instead of making the whole document
                // unopenable. No byte is ever rewritten unless it belongs to a
                // successfully parsed text string.
                parser.index += 1
                operands.removeAll(keepingCapacity: true)
                continue
            }
            operations.append(PDFContentOperation(name: name, operands: operands,
                                                   operatorRange: PDFByteRange(start, parser.index)))
            operands.removeAll(keepingCapacity: true)
            if name == "BI" { skipInlineImage(bytes: bytes, parser: &parser) }
        }
        return operations
    }

    private static func beginsObject(_ byte: UInt8, parser: PDFSyntaxParser) -> Bool {
        if byte == 0x2F || byte == 0x28 || byte == 0x3C || byte == 0x5B { return true }
        if byte == 0x2B || byte == 0x2D || byte == 0x2E || byte.isASCIIDigit { return true }
        let rest = String(decoding: parser.bytes[parser.index..<min(parser.index + 5, parser.bytes.count)], as: UTF8.self)
        return rest.hasPrefix("true") || rest.hasPrefix("false") || rest.hasPrefix("null")
    }

    private static func stringTokens(in bytes: [UInt8], range: Range<Int>, root: PDFObject)
        -> [PDFContentStringToken] {
        switch root {
        case .string(let data): return [PDFContentStringToken(data: data,
                                                               range: PDFByteRange(range.lowerBound, range.upperBound))]
        case .array:
            var parser = PDFSyntaxParser(bytes: bytes, offset: range.lowerBound + 1)
            var result: [PDFContentStringToken] = []
            while parser.index < range.upperBound - 1 {
                parser.skipSpaceAndComments()
                guard parser.index < range.upperBound - 1 else { break }
                let start = parser.index
                guard let object = try? parser.parseObject() else { break }
                let end = parser.index
                switch object {
                case .string(let data):
                    result.append(PDFContentStringToken(data: data, range: PDFByteRange(start, end)))
                case .array:
                    result.append(contentsOf: stringTokens(in: bytes, range: start..<end, root: object))
                default: break
                }
            }
            return result
        default: return []
        }
    }

    /// Inline-image data may contain arbitrary bytes that look like operators.
    /// Consume the parameter dictionary through `ID`, then find `EI` only at
    /// whitespace-delimited boundaries as required by the PDF grammar.
    private static func skipInlineImage(bytes: [UInt8], parser: inout PDFSyntaxParser) {
        while parser.index < bytes.count {
            parser.skipSpaceAndComments()
            let token = parser.parseRegularToken()
            if token == "ID" {
                if parser.peek() == 0x0D { parser.index += 1; if parser.peek() == 0x0A { parser.index += 1 } }
                else if parser.peek().map(PDFSyntaxParser.isWhitespace) == true { parser.index += 1 }
                break
            }
            if token.isEmpty { parser.index += 1 }
        }
        while parser.index + 1 < bytes.count {
            if bytes[parser.index] == 0x45, bytes[parser.index + 1] == 0x49,
               parser.index > 0, PDFSyntaxParser.isWhitespace(bytes[parser.index - 1]),
               (parser.index + 2 == bytes.count || PDFSyntaxParser.isWhitespace(bytes[parser.index + 2])) {
                parser.index += 2
                return
            }
            parser.index += 1
        }
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (0x30...0x39).contains(self) }
}
