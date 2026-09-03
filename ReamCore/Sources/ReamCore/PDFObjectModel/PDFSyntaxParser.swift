import Foundation

struct PDFSyntaxParser {
    let bytes: [UInt8]
    var index: Int

    init(data: Data, offset: Int = 0) {
        self.bytes = Array(data)
        self.index = offset
    }

    init(bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.index = offset
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipSpaceAndComments() {
        while index < bytes.count {
            if Self.isWhitespace(bytes[index]) {
                index += 1
            } else if bytes[index] == 0x25 { // % comment
                index += 1
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
            } else {
                break
            }
        }
    }

    mutating func parseObject() throws -> PDFObject {
        skipSpaceAndComments()
        guard index < bytes.count else {
            throw PDFObjectError.malformedObject(offset: index, reason: "unexpected end of data")
        }

        switch bytes[index] {
        case 0x2F: return .name(try parseName()) // /
        case 0x28: return .string(try parseLiteralString()) // (
        case 0x3C:
            if peek(1) == 0x3C { return .dictionary(try parseDictionary()) }
            return .string(try parseHexString())
        case 0x5B: return .array(try parseArray()) // [
        default:
            let start = index
            let token = parseRegularToken()
            switch token {
            case "null": return .null
            case "true": return .boolean(true)
            case "false": return .boolean(false)
            default:
                guard Self.looksNumeric(token) else {
                    throw PDFObjectError.malformedObject(offset: start, reason: "unexpected token \(token)")
                }
                if let first = Int(token) {
                    let afterFirst = index
                    skipSpaceAndComments()
                    let secondStart = index
                    let second = parseRegularToken()
                    if let generation = Int(second) {
                        skipSpaceAndComments()
                        if consumeKeyword("R") {
                            return .reference(PDFObjectReference(first, generation))
                        }
                    }
                    index = afterFirst
                    _ = secondStart
                    return .integer(first)
                }
                guard let value = Double(token) else {
                    throw PDFObjectError.malformedObject(offset: start, reason: "invalid number")
                }
                return .real(value)
            }
        }
    }

    mutating func parseIndirectObject(
        expected: PDFObjectReference? = nil,
        resolveStreamLength: ((PDFObject) throws -> Int?)? = nil
    ) throws -> (PDFObjectReference, PDFObject) {
        skipSpaceAndComments()
        let start = index
        guard let number = Int(parseRegularToken()) else {
            throw PDFObjectError.malformedObject(offset: start, reason: "missing object number")
        }
        skipSpaceAndComments()
        guard let generation = Int(parseRegularToken()) else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing generation")
        }
        skipSpaceAndComments()
        guard consumeKeyword("obj") else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing obj keyword")
        }
        let reference = PDFObjectReference(number, generation)
        if let expected, expected != reference {
            throw PDFObjectError.malformedObject(offset: start, reason: "xref points at \(reference), expected \(expected)")
        }

        var object = try parseObject()
        if case .dictionary(let dictionary) = object {
            let afterDictionary = index
            skipSpaceAndComments()
            if consumeKeyword("stream") {
                // The EOL after `stream` is syntax, not stream data.
                if peek() == 0x0D { index += 1; if peek() == 0x0A { index += 1 } }
                else if peek() == 0x0A { index += 1 }
                let streamStart = index
                var length = dictionary["Length"]?.intValue
                if length == nil, let lengthObject = dictionary["Length"], let resolveStreamLength {
                    length = try resolveStreamLength(lengthObject)
                }
                if let directLength = length,
                   directLength >= 0,
                   streamStart + directLength <= bytes.count {
                    index = streamStart + directLength
                    skipSpaceAndComments()
                    if !consumeKeyword("endstream") { length = nil }
                }
                if length == nil {
                    guard let end = findKeyword("endstream", from: streamStart) else {
                        throw PDFObjectError.corruptStream("missing endstream")
                    }
                    // Without a trustworthy /Length there is no principled way
                    // to distinguish a payload CR/LF from the endstream EOL.
                    // Preserve every byte instead of silently deleting data.
                    length = end - streamStart
                    index = end + 9
                }
                let end = streamStart + (length ?? 0)
                object = .stream(PDFStream(dictionary: dictionary,
                                           data: Data(bytes[streamStart..<end])))
            } else {
                index = afterDictionary
            }
        }
        skipSpaceAndComments()
        _ = consumeKeyword("endobj")
        return (reference, object)
    }

    mutating func parseDictionary() throws -> [String: PDFObject] {
        guard peek() == 0x3C, peek(1) == 0x3C else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing <<")
        }
        index += 2
        var result: [String: PDFObject] = [:]
        while true {
            skipSpaceAndComments()
            if peek() == 0x3E, peek(1) == 0x3E { index += 2; return result }
            guard peek() == 0x2F else {
                throw PDFObjectError.malformedObject(offset: index, reason: "dictionary key is not a name")
            }
            let key = try parseName()
            result[key] = try parseObject()
        }
    }

    mutating func parseArray() throws -> [PDFObject] {
        guard peek() == 0x5B else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing [")
        }
        index += 1
        var result: [PDFObject] = []
        while true {
            skipSpaceAndComments()
            guard index < bytes.count else {
                throw PDFObjectError.malformedObject(offset: index, reason: "unterminated array")
            }
            if peek() == 0x5D { index += 1; return result }
            result.append(try parseObject())
        }
    }

    mutating func parseName() throws -> String {
        guard peek() == 0x2F else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing /")
        }
        index += 1
        var output: [UInt8] = []
        while index < bytes.count, !Self.isDelimiter(bytes[index]), !Self.isWhitespace(bytes[index]) {
            if bytes[index] == 0x23, index + 2 < bytes.count,
               let high = Self.hex(bytes[index + 1]), let low = Self.hex(bytes[index + 2]) {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    mutating func parseLiteralString() throws -> Data {
        guard peek() == 0x28 else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing (")
        }
        index += 1
        var depth = 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x28 { depth += 1; output.append(byte); continue }
            if byte == 0x29 {
                depth -= 1
                if depth == 0 { return Data(output) }
                output.append(byte); continue
            }
            guard byte == 0x5C else { output.append(byte); continue }
            guard index < bytes.count else { break }
            let escaped = bytes[index]
            index += 1
            switch escaped {
            case 0x6E: output.append(0x0A) // n
            case 0x72: output.append(0x0D) // r
            case 0x74: output.append(0x09) // t
            case 0x62: output.append(0x08) // b
            case 0x66: output.append(0x0C) // f
            case 0x28, 0x29, 0x5C: output.append(escaped)
            case 0x0D: if peek() == 0x0A { index += 1 }
            case 0x0A: break
            case 0x30...0x37:
                var value = Int(escaped - 0x30)
                var count = 1
                while count < 3, index < bytes.count, (0x30...0x37).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - 0x30)
                    index += 1; count += 1
                }
                output.append(UInt8(value & 0xFF))
            default: output.append(escaped)
            }
        }
        throw PDFObjectError.malformedObject(offset: index, reason: "unterminated string")
    }

    mutating func parseHexString() throws -> Data {
        guard peek() == 0x3C, peek(1) != 0x3C else {
            throw PDFObjectError.malformedObject(offset: index, reason: "missing <")
        }
        index += 1
        var nibbles: [UInt8] = []
        while index < bytes.count, bytes[index] != 0x3E {
            if let nibble = Self.hex(bytes[index]) { nibbles.append(nibble) }
            else if !Self.isWhitespace(bytes[index]) {
                throw PDFObjectError.malformedObject(offset: index, reason: "invalid hex string")
            }
            index += 1
        }
        guard peek() == 0x3E else {
            throw PDFObjectError.malformedObject(offset: index, reason: "unterminated hex string")
        }
        index += 1
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        var output: [UInt8] = []
        output.reserveCapacity(nibbles.count / 2)
        for i in stride(from: 0, to: nibbles.count, by: 2) {
            output.append(nibbles[i] << 4 | nibbles[i + 1])
        }
        return Data(output)
    }

    mutating func parseRegularToken() -> String {
        let start = index
        while index < bytes.count,
              !Self.isWhitespace(bytes[index]),
              !Self.isDelimiter(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    mutating func consumeKeyword(_ keyword: String) -> Bool {
        let value = Array(keyword.utf8)
        guard index + value.count <= bytes.count,
              Array(bytes[index..<(index + value.count)]) == value else { return false }
        let next = index + value.count
        guard next == bytes.count || Self.isWhitespace(bytes[next]) || Self.isDelimiter(bytes[next]) else { return false }
        index = next
        return true
    }

    func findKeyword(_ keyword: String, from start: Int) -> Int? {
        let needle = Array(keyword.utf8)
        guard !needle.isEmpty, start < bytes.count else { return nil }
        var cursor = start
        while cursor + needle.count <= bytes.count {
            if bytes[cursor..<(cursor + needle.count)].elementsEqual(needle) { return cursor }
            cursor += 1
        }
        return nil
    }

    func peek(_ distance: Int = 0) -> UInt8? {
        let position = index + distance
        return position >= 0 && position < bytes.count ? bytes[position] : nil
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25].contains(byte)
    }

    static func looksNumeric(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" }
    }

    static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

enum PDFObjectSerializer {
    static func data(for object: PDFObject) -> Data {
        var output = Data()
        append(object, to: &output)
        return output
    }

    private static func append(_ object: PDFObject, to output: inout Data) {
        switch object {
        case .null: output.appendASCII("null")
        case .boolean(let value): output.appendASCII(value ? "true" : "false")
        case .integer(let value): output.appendASCII(String(value))
        case .real(let value):
            var text = String(format: "%.8f", value)
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
            output.appendASCII(text)
        case .name(let value):
            output.append(0x2F)
            for byte in value.utf8 {
                if PDFSyntaxParser.isWhitespace(byte) || PDFSyntaxParser.isDelimiter(byte) || byte < 0x21 || byte > 0x7E {
                    output.appendASCII(String(format: "#%02X", byte))
                } else { output.append(byte) }
            }
        case .string(let value):
            output.append(0x3C)
            output.appendASCII(value.map { String(format: "%02X", $0) }.joined())
            output.append(0x3E)
        case .array(let values):
            output.append(0x5B)
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(0x20) }
                append(value, to: &output)
            }
            output.append(0x5D)
        case .dictionary(let dictionary):
            output.appendASCII("<<")
            for key in dictionary.keys.sorted() {
                output.append(0x20)
                append(.name(key), to: &output)
                output.append(0x20)
                append(dictionary[key]!, to: &output)
            }
            output.appendASCII(" >>")
        case .stream(let stream):
            var dictionary = stream.dictionary
            dictionary["Length"] = .integer(stream.data.count)
            append(.dictionary(dictionary), to: &output)
            output.appendASCII("\nstream\n")
            output.append(stream.data)
            output.appendASCII("\nendstream")
        case .reference(let reference):
            output.appendASCII("\(reference.objectNumber) \(reference.generation) R")
        }
    }
}

extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
