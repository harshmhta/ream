import Foundation
import zlib

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

    /// Inline-image data may contain arbitrary bytes, including complete fake
    /// content programs followed by whitespace-delimited `EI`. Determine the
    /// payload boundary from the declared raster dimensions when unfiltered,
    /// or from the outer filter's end marker. If no trustworthy boundary can be
    /// found, conservatively hide the rest of the stream from text editing.
    private static func skipInlineImage(bytes: [UInt8], parser: inout PDFSyntaxParser) {
        var parameters: [String: PDFObject] = [:]
        var dataStart: Int?
        while parser.index < bytes.count {
            parser.skipSpaceAndComments()
            if parser.peek() == 0x2F {
                guard let key = try? parser.parseName() else { parser.index += 1; continue }
                parser.skipSpaceAndComments()
                if let value = try? parser.parseObject() { parameters[key] = value }
                continue
            }
            let token = parser.parseRegularToken()
            if token == "ID" {
                if parser.peek() == 0x0D { parser.index += 1; if parser.peek() == 0x0A { parser.index += 1 } }
                else if parser.peek().map(PDFSyntaxParser.isWhitespace) == true { parser.index += 1 }
                dataStart = parser.index
                break
            }
            if token.isEmpty { parser.index += 1 }
        }
        guard let start = dataStart else { parser.index = bytes.count; return }

        let end: Int?
        if parameters["F"] == nil, parameters["Filter"] == nil {
            end = unfilteredImageByteCount(parameters).map { start + $0 }
        } else {
            let filter = parameters["F"] ?? parameters["Filter"]
            end = encodedImageEnd(bytes: bytes, start: start, filter: filter)
        }
        guard let end, end >= start, end <= bytes.count,
              consumeInlineImageEnd(bytes: bytes, after: end, parser: &parser) else {
            parser.index = bytes.count
            return
        }
    }

    private static func unfilteredImageByteCount(_ parameters: [String: PDFObject]) -> Int? {
        guard let width = (parameters["W"] ?? parameters["Width"])?.intValue,
              let height = (parameters["H"] ?? parameters["Height"])?.intValue,
              width >= 0, height >= 0 else { return nil }
        let imageMask: Bool
        if case .boolean(let value) = parameters["IM"] ?? parameters["ImageMask"] { imageMask = value }
        else { imageMask = false }
        let bits = imageMask ? 1 : ((parameters["BPC"] ?? parameters["BitsPerComponent"])?.intValue ?? 8)
        guard bits > 0, let components = imageMask ? 1 : colorComponents(parameters["CS"] ?? parameters["ColorSpace"]) else {
            return nil
        }
        let (bitsPerPixel, componentOverflow) = components.multipliedReportingOverflow(by: bits)
        let (rowBits, rowOverflow) = width.multipliedReportingOverflow(by: bitsPerPixel)
        let (roundedRowBits, roundingOverflow) = rowBits.addingReportingOverflow(7)
        guard !componentOverflow, !rowOverflow, !roundingOverflow else { return nil }
        let (total, totalOverflow) = (roundedRowBits / 8).multipliedReportingOverflow(by: height)
        return totalOverflow ? nil : total
    }

    private static func colorComponents(_ object: PDFObject?) -> Int? {
        switch object {
        case .name(let name):
            switch name {
            case "G", "DeviceGray": return 1
            case "RGB", "DeviceRGB": return 3
            case "CMYK", "DeviceCMYK": return 4
            default: return nil // a resource name needs page resources to resolve
            }
        case .array(let values):
            switch values.first?.nameValue {
            case "I", "Indexed", "Separation": return 1
            case "DeviceN": return values.count > 1 ? values[1].arrayValue?.count : nil
            default: return nil
            }
        default: return nil
        }
    }

    private static func encodedImageEnd(bytes: [UInt8], start: Int, filter: PDFObject?) -> Int? {
        let firstFilter: String?
        if let name = filter?.nameValue { firstFilter = name }
        else { firstFilter = filter?.arrayValue?.first?.nameValue }
        switch firstFilter {
        case "ASCIIHexDecode", "AHx":
            return bytes[start...].firstIndex(of: 0x3E).map { $0 + 1 }
        case "ASCII85Decode", "A85":
            guard start + 1 < bytes.count else { return nil }
            for index in start..<(bytes.count - 1)
                where bytes[index] == 0x7E && bytes[index + 1] == 0x3E { return index + 2 }
            return nil
        case "RunLengthDecode", "RL":
            var index = start
            while index < bytes.count {
                let control = Int(bytes[index]); index += 1
                if control == 128 { return index }
                index += control <= 127 ? control + 1 : 1
                if index > bytes.count { return nil }
            }
            return nil
        case "FlateDecode", "Fl": return flateEnd(bytes: bytes, start: start)
        case "DCTDecode", "DCT", "JPXDecode":
            guard start + 1 < bytes.count else { return nil }
            for index in start..<(bytes.count - 1)
                where bytes[index] == 0xFF && bytes[index + 1] == 0xD9 { return index + 2 }
            return nil
        default: return nil
        }
    }

    private static func flateEnd(bytes: [UInt8], start: Int) -> Int? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let outputCapacity = 4096
        var output = [UInt8](repeating: 0, count: outputCapacity)
        return bytes.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress! + start)
                stream.avail_in = uInt(bytes.count - start)
                repeat {
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = uInt(outputCapacity)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    if status == Z_STREAM_END { return start + Int(stream.total_in) }
                    if status != Z_OK || (stream.avail_in == 0 && stream.avail_out > 0) { return nil }
                } while true
            }
        }
    }

    private static func consumeInlineImageEnd(bytes: [UInt8], after payloadEnd: Int,
                                              parser: inout PDFSyntaxParser) -> Bool {
        parser.index = payloadEnd
        while parser.index < bytes.count, PDFSyntaxParser.isWhitespace(bytes[parser.index]) {
            parser.index += 1
        }
        guard parser.index + 1 < bytes.count,
              bytes[parser.index] == 0x45, bytes[parser.index + 1] == 0x49,
              parser.index + 2 == bytes.count || PDFSyntaxParser.isWhitespace(bytes[parser.index + 2]) else {
            return false
        }
        parser.index += 2
        return true
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (0x30...0x39).contains(self) }
}
