import Foundation

enum PDFXRefEntry: Equatable {
    case free(next: Int, generation: Int)
    case uncompressed(offset: Int, generation: Int)
    case compressed(objectStream: Int, index: Int)
}

enum PDFXRefStyle { case table, stream }

/// Parsed, lazily-resolved PDF objects. Cross-reference sections are followed
/// through every incremental revision; corrupt entries transparently fall back
/// to an object-header scan.
final class PDFParsedDocument {
    let data: Data
    let bytes: [UInt8]
    private(set) var trailer: [String: PDFObject] = [:]
    private(set) var latestXRefOffset: Int = 0
    private(set) var xrefStyle: PDFXRefStyle = .table
    private(set) var entries: [Int: PDFXRefEntry] = [:]
    private var cache: [PDFObjectReference: PDFObject] = [:]
    private var objectStreamCache: [Int: [Int: PDFObject]] = [:]
    private lazy var scannedOffsets: [PDFObjectReference: Int] = scanObjectHeaders()

    init(data: Data) throws {
        self.data = data
        self.bytes = Array(data)
        guard bytes.count >= 5,
              String(decoding: bytes.prefix(1024), as: UTF8.self).contains("%PDF-") else {
            throw PDFObjectError.invalidHeader
        }

        guard let start = Self.findStartXRef(in: bytes) else {
            // A missing startxref is recoverable for reading. Writing uses a
            // classic incremental section whose /Prev is omitted.
            reconstructAllObjects()
            return
        }
        latestXRefOffset = start
        do {
            var visited = Set<Int>()
            try readXRefChain(at: start, newest: true, visited: &visited)
        } catch {
            entries.removeAll()
            trailer.removeAll()
            reconstructAllObjects()
        }
    }

    var size: Int {
        max(trailer["Size"]?.intValue ?? 0,
            (entries.keys.max() ?? scannedOffsets.keys.map(\.objectNumber).max() ?? 0) + 1)
    }

    func object(_ reference: PDFObjectReference) throws -> PDFObject {
        if let cached = cache[reference] { return cached }
        if let entry = entries[reference.objectNumber] {
            switch entry {
            case .uncompressed(let offset, let generation):
                do {
                    var parser = PDFSyntaxParser(bytes: bytes, offset: offset)
                    let (_, object) = try parser.parseIndirectObject(
                        expected: PDFObjectReference(reference.objectNumber, generation))
                    cache[reference] = object
                    return object
                } catch {
                    break
                }
            case .compressed(let streamNumber, let objectIndex):
                let objects = try objects(in: streamNumber)
                if let object = objects[reference.objectNumber] {
                    cache[reference] = object
                    return object
                }
                // A few damaged producers get the object number wrong but keep
                // the object-stream index usable.
                if objectIndex >= 0, objectIndex < objects.count,
                   let object = Array(objects.sorted { $0.key < $1.key })[objectIndex].value as PDFObject? {
                    cache[reference] = object
                    return object
                }
            case .free: break
            }
        }
        if let offset = scannedOffsets[reference]
            ?? scannedOffsets.first(where: { $0.key.objectNumber == reference.objectNumber })?.value {
            var parser = PDFSyntaxParser(bytes: bytes, offset: offset)
            let (_, object) = try parser.parseIndirectObject()
            cache[reference] = object
            return object
        }
        throw PDFObjectError.missingObject(reference)
    }

    func dereference(_ object: PDFObject?) throws -> PDFObject? {
        guard let object else { return nil }
        if case .reference(let reference) = object { return try self.object(reference) }
        return object
    }

    func dictionary(_ object: PDFObject?) throws -> [String: PDFObject]? {
        try dereference(object)?.dictionaryValue
    }

    func stream(_ object: PDFObject?) throws -> PDFStream? {
        guard let resolved = try dereference(object), case .stream(let stream) = resolved else { return nil }
        return stream
    }

    private func objects(in objectStreamNumber: Int) throws -> [Int: PDFObject] {
        if let cached = objectStreamCache[objectStreamNumber] { return cached }
        let reference = PDFObjectReference(objectStreamNumber, 0)
        guard case .stream(let stream) = try object(reference) else {
            throw PDFObjectError.corruptStream("ObjStm \(objectStreamNumber) is not a stream")
        }
        let decoded = try PDFStreamFilters.decode(stream)
        let n = stream.dictionary["N"]?.intValue ?? 0
        let first = stream.dictionary["First"]?.intValue ?? 0
        guard n >= 0, first >= 0, first <= decoded.count else {
            throw PDFObjectError.corruptStream("invalid ObjStm header")
        }
        var header = PDFSyntaxParser(data: decoded)
        var pairs: [(Int, Int)] = []
        for _ in 0..<n {
            header.skipSpaceAndComments()
            guard let number = Int(header.parseRegularToken()) else {
                throw PDFObjectError.corruptStream("invalid ObjStm object number")
            }
            header.skipSpaceAndComments()
            guard let offset = Int(header.parseRegularToken()) else {
                throw PDFObjectError.corruptStream("invalid ObjStm offset")
            }
            pairs.append((number, offset))
        }
        var result: [Int: PDFObject] = [:]
        let decodedBytes = Array(decoded)
        for pair in pairs {
            var parser = PDFSyntaxParser(bytes: decodedBytes, offset: first + pair.1)
            result[pair.0] = try parser.parseObject()
        }
        objectStreamCache[objectStreamNumber] = result
        return result
    }

    private func readXRefChain(at offset: Int, newest: Bool, visited: inout Set<Int>) throws {
        guard offset >= 0, offset < bytes.count, visited.insert(offset).inserted else { return }
        var parser = PDFSyntaxParser(bytes: bytes, offset: offset)
        parser.skipSpaceAndComments()
        let sectionEntries: [Int: PDFXRefEntry]
        let sectionTrailer: [String: PDFObject]
        if parser.consumeKeyword("xref") {
            if newest { xrefStyle = .table }
            (sectionEntries, sectionTrailer) = try parseClassicXRef(parser: &parser)
        } else {
            if newest { xrefStyle = .stream }
            (sectionEntries, sectionTrailer) = try parseXRefStream(offset: offset)
        }
        for (number, entry) in sectionEntries where entries[number] == nil { entries[number] = entry }
        for (key, value) in sectionTrailer where trailer[key] == nil { trailer[key] = value }

        // Hybrid files keep compressed-object entries in a companion xref stream.
        if let hybrid = sectionTrailer["XRefStm"]?.intValue, !visited.contains(hybrid) {
            visited.insert(hybrid)
            let (hybridEntries, hybridTrailer) = try parseXRefStream(offset: hybrid)
            for (number, entry) in hybridEntries {
                if entries[number] == nil { entries[number] = entry }
                else if let current = entries[number], case .free = current,
                        case .compressed = entry { entries[number] = entry }
            }
            for (key, value) in hybridTrailer where trailer[key] == nil { trailer[key] = value }
        }
        if let previous = sectionTrailer["Prev"]?.intValue {
            try readXRefChain(at: previous, newest: false, visited: &visited)
        }
    }

    private func parseClassicXRef(parser: inout PDFSyntaxParser) throws
        -> ([Int: PDFXRefEntry], [String: PDFObject]) {
        var result: [Int: PDFXRefEntry] = [:]
        while true {
            parser.skipSpaceAndComments()
            if parser.consumeKeyword("trailer") {
                guard case .dictionary(let dictionary) = try parser.parseObject() else {
                    throw PDFObjectError.malformedObject(offset: parser.index, reason: "invalid trailer")
                }
                return (result, dictionary)
            }
            guard let first = Int(parser.parseRegularToken()) else {
                throw PDFObjectError.malformedObject(offset: parser.index, reason: "invalid xref subsection")
            }
            parser.skipSpaceAndComments()
            guard let count = Int(parser.parseRegularToken()), count >= 0 else {
                throw PDFObjectError.malformedObject(offset: parser.index, reason: "invalid xref count")
            }
            for number in first..<(first + count) {
                parser.skipSpaceAndComments()
                guard let offset = Int(parser.parseRegularToken()) else {
                    throw PDFObjectError.malformedObject(offset: parser.index, reason: "invalid xref offset")
                }
                parser.skipSpaceAndComments()
                guard let generation = Int(parser.parseRegularToken()) else {
                    throw PDFObjectError.malformedObject(offset: parser.index, reason: "invalid xref generation")
                }
                parser.skipSpaceAndComments()
                let state = parser.parseRegularToken()
                result[number] = state == "n" ? .uncompressed(offset: offset, generation: generation)
                                               : .free(next: offset, generation: generation)
            }
        }
    }

    private func parseXRefStream(offset: Int) throws
        -> ([Int: PDFXRefEntry], [String: PDFObject]) {
        var parser = PDFSyntaxParser(bytes: bytes, offset: offset)
        let (_, object) = try parser.parseIndirectObject()
        guard case .stream(let stream) = object else {
            throw PDFObjectError.malformedObject(offset: offset, reason: "xref is not a stream")
        }
        let widths = stream.dictionary["W"]?.arrayValue?.compactMap(\.intValue) ?? []
        guard widths.count == 3, widths.allSatisfy({ $0 >= 0 }) else {
            throw PDFObjectError.corruptStream("xref stream has invalid /W")
        }
        let size = stream.dictionary["Size"]?.intValue ?? 0
        var ranges = stream.dictionary["Index"]?.arrayValue?.compactMap(\.intValue) ?? [0, size]
        guard ranges.count % 2 == 0 else {
            throw PDFObjectError.corruptStream("xref stream has invalid /Index")
        }
        let decoded = Array(try PDFStreamFilters.decode(stream))
        let rowWidth = widths.reduce(0, +)
        guard rowWidth > 0 else { throw PDFObjectError.corruptStream("empty xref rows") }
        var byteOffset = 0
        var entries: [Int: PDFXRefEntry] = [:]
        while !ranges.isEmpty {
            let first = ranges.removeFirst(), count = ranges.removeFirst()
            for number in first..<(first + count) {
                guard byteOffset + rowWidth <= decoded.count else {
                    throw PDFObjectError.corruptStream("short xref stream")
                }
                let type = widths[0] == 0 ? 1 : readBigEndian(decoded, offset: byteOffset, count: widths[0])
                byteOffset += widths[0]
                let field2 = readBigEndian(decoded, offset: byteOffset, count: widths[1]); byteOffset += widths[1]
                let field3 = readBigEndian(decoded, offset: byteOffset, count: widths[2]); byteOffset += widths[2]
                switch type {
                case 0: entries[number] = .free(next: field2, generation: field3)
                case 1: entries[number] = .uncompressed(offset: field2, generation: field3)
                case 2: entries[number] = .compressed(objectStream: field2, index: field3)
                default: break
                }
            }
        }
        return (entries, stream.dictionary)
    }

    private func readBigEndian(_ bytes: [UInt8], offset: Int, count: Int) -> Int {
        var result = 0
        for index in 0..<count { result = (result << 8) | Int(bytes[offset + index]) }
        return result
    }

    private func reconstructAllObjects() {
        for (reference, offset) in scannedOffsets {
            entries[reference.objectNumber] = .uncompressed(offset: offset, generation: reference.generation)
        }
        // A scanned trailer still supplies Root/Info/ID when an xref is broken.
        if let trailerOffset = lastKeyword("trailer") {
            var parser = PDFSyntaxParser(bytes: bytes, offset: trailerOffset + 7)
            if let object = try? parser.parseObject(), case .dictionary(let dictionary) = object {
                trailer = dictionary
            }
        }
    }

    private func scanObjectHeaders() -> [PDFObjectReference: Int] {
        var result: [PDFObjectReference: Int] = [:]
        var cursor = 0
        while cursor < bytes.count {
            guard bytes[cursor].isASCIIDigit,
                  cursor == 0 || PDFSyntaxParser.isWhitespace(bytes[cursor - 1]) else {
                cursor += 1; continue
            }
            var parser = PDFSyntaxParser(bytes: bytes, offset: cursor)
            let start = cursor
            let first = parser.parseRegularToken()
            parser.skipSpaceAndComments()
            let second = parser.parseRegularToken()
            parser.skipSpaceAndComments()
            if let number = Int(first), let generation = Int(second), parser.consumeKeyword("obj") {
                result[PDFObjectReference(number, generation)] = start
            }
            cursor += max(1, parser.index - cursor)
        }
        return result
    }

    private func lastKeyword(_ keyword: String) -> Int? {
        let needle = Array(keyword.utf8)
        guard bytes.count >= needle.count else { return nil }
        for offset in stride(from: bytes.count - needle.count, through: 0, by: -1)
            where bytes[offset..<(offset + needle.count)].elementsEqual(needle) { return offset }
        return nil
    }

    private static func findStartXRef(in bytes: [UInt8]) -> Int? {
        let needle = Array("startxref".utf8)
        guard bytes.count >= needle.count else { return nil }
        for offset in stride(from: bytes.count - needle.count, through: 0, by: -1) {
            guard bytes[offset..<(offset + needle.count)].elementsEqual(needle) else { continue }
            var parser = PDFSyntaxParser(bytes: bytes, offset: offset + needle.count)
            parser.skipSpaceAndComments()
            return Int(parser.parseRegularToken())
        }
        return nil
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (0x30...0x39).contains(self) }
}
