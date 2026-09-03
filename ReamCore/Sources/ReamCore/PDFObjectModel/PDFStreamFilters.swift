import Foundation
import zlib

/// Dependency-free decoders for the filters used by content, object and
/// cross-reference streams. Image-only codecs deliberately remain opaque.
public enum PDFStreamFilters {
    public static func decode(_ stream: PDFStream) throws -> Data {
        try decode(stream.data,
                   filters: stream.dictionary["Filter"],
                   parameters: stream.dictionary["DecodeParms"] ?? stream.dictionary["DP"])
    }

    public static func decode(_ data: Data,
                              filters filterObject: PDFObject?,
                              parameters parameterObject: PDFObject? = nil) throws -> Data {
        let filters: [String]
        switch filterObject {
        case nil: return data
        case .name(let name): filters = [name]
        case .array(let values): filters = values.compactMap(\.nameValue)
        default: throw PDFObjectError.corruptStream("Filter must be a name or array")
        }

        let parameterSets: [[String: PDFObject]?]
        switch parameterObject {
        case .dictionary(let dictionary): parameterSets = [dictionary]
        case .array(let values): parameterSets = values.map { $0.dictionaryValue }
        default: parameterSets = []
        }

        var result = data
        for (index, filter) in filters.enumerated() {
            let parameters = index < parameterSets.count ? parameterSets[index] : nil
            switch filter {
            case "FlateDecode", "Fl":
                result = try flate(result)
                result = try applyPredictor(result, parameters: parameters)
            case "ASCIIHexDecode", "AHx": result = try asciiHex(result)
            case "ASCII85Decode", "A85": result = try ascii85(result)
            case "LZWDecode", "LZW":
                result = try lzw(result, earlyChange: parameters?["EarlyChange"]?.intValue ?? 1)
                result = try applyPredictor(result, parameters: parameters)
            case "RunLengthDecode", "RL": result = try runLength(result)
            default: throw PDFObjectError.unsupportedFilter(filter)
            }
        }
        return result
    }

    private static func flate(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        return try input.withUnsafeBytes { sourceRaw in
            guard let source = sourceRaw.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            var capacity = max(4096, input.count * 3)
            for _ in 0..<18 {
                var output = [UInt8](repeating: 0, count: capacity)
                var decoded = uLongf(capacity)
                let status = output.withUnsafeMutableBytes { destinationRaw in
                    uncompress(destinationRaw.bindMemory(to: UInt8.self).baseAddress!,
                               &decoded, source, uLong(input.count))
                }
                if status == Z_OK { return Data(output[0..<Int(decoded)]) }
                if status != Z_BUF_ERROR { break }
                capacity *= 2
            }
            throw PDFObjectError.corruptStream("FlateDecode failed")
        }
    }

    private static func asciiHex(_ input: Data) throws -> Data {
        var nibbles: [UInt8] = []
        for byte in input {
            if byte == 0x3E { break }
            if PDFSyntaxParser.isWhitespace(byte) { continue }
            guard let value = PDFSyntaxParser.hex(byte) else {
                throw PDFObjectError.corruptStream("invalid ASCIIHex digit")
            }
            nibbles.append(value)
        }
        if nibbles.count % 2 == 1 { nibbles.append(0) }
        var result = Data(capacity: nibbles.count / 2)
        for index in stride(from: 0, to: nibbles.count, by: 2) {
            result.append(nibbles[index] << 4 | nibbles[index + 1])
        }
        return result
    }

    private static func ascii85(_ input: Data) throws -> Data {
        var bytes = Array(input)
        if bytes.starts(with: [0x3C, 0x7E]) { bytes.removeFirst(2) } // <~
        var group: [UInt8] = []
        var result = Data()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if PDFSyntaxParser.isWhitespace(byte) { continue }
            if byte == 0x7E { break } // ~>
            if byte == 0x7A { // z
                guard group.isEmpty else { throw PDFObjectError.corruptStream("ASCII85 z inside tuple") }
                result.append(contentsOf: [0, 0, 0, 0]); continue
            }
            guard (0x21...0x75).contains(byte) else {
                throw PDFObjectError.corruptStream("invalid ASCII85 digit")
            }
            group.append(byte - 0x21)
            if group.count == 5 {
                appendASCII85(group, count: 4, to: &result)
                group.removeAll(keepingCapacity: true)
            }
        }
        if group.count == 1 { throw PDFObjectError.corruptStream("short ASCII85 tuple") }
        if !group.isEmpty {
            let count = group.count - 1
            while group.count < 5 { group.append(84) }
            appendASCII85(group, count: count, to: &result)
        }
        return result
    }

    private static func appendASCII85(_ digits: [UInt8], count: Int, to output: inout Data) {
        var value: UInt64 = 0
        for digit in digits { value = value * 85 + UInt64(digit) }
        let tuple = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        output.append(contentsOf: tuple.prefix(count))
    }

    private static func runLength(_ input: Data) throws -> Data {
        let bytes = Array(input)
        var index = 0
        var result = Data()
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            if length == 128 { break }
            if length <= 127 {
                let count = length + 1
                guard index + count <= bytes.count else {
                    throw PDFObjectError.corruptStream("short RunLength literal")
                }
                result.append(contentsOf: bytes[index..<(index + count)])
                index += count
            } else {
                guard index < bytes.count else {
                    throw PDFObjectError.corruptStream("short RunLength repeat")
                }
                result.append(contentsOf: repeatElement(bytes[index], count: 257 - length))
                index += 1
            }
        }
        return result
    }

    private static func lzw(_ input: Data, earlyChange: Int) throws -> Data {
        var reader = MSBBitReader(bytes: Array(input))
        var table = (0..<256).map { [UInt8($0)] }
        table.append([]) // 256 clear
        table.append([]) // 257 end
        var codeWidth = 9
        var previous: [UInt8]?
        var output = Data()

        while let code = reader.read(codeWidth) {
            if code == 256 {
                table = (0..<256).map { [UInt8($0)] } + [[], []]
                codeWidth = 9
                previous = nil
                continue
            }
            if code == 257 { break }
            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if code == table.count, let previous, let first = previous.first {
                entry = previous + [first]
            } else {
                throw PDFObjectError.corruptStream("invalid LZW code \(code)")
            }
            output.append(contentsOf: entry)
            if let previous, let first = entry.first, table.count < 4096 {
                table.append(previous + [first])
                let threshold = (1 << codeWidth) - (earlyChange == 0 ? 0 : 1)
                if table.count == threshold, codeWidth < 12 { codeWidth += 1 }
            }
            previous = entry
        }
        return output
    }

    private static func applyPredictor(_ input: Data,
                                       parameters: [String: PDFObject]?) throws -> Data {
        let predictor = parameters?["Predictor"]?.intValue ?? 1
        guard predictor != 1 else { return input }
        let colors = max(1, parameters?["Colors"]?.intValue ?? 1)
        let bits = max(1, parameters?["BitsPerComponent"]?.intValue ?? 8)
        let columns = max(1, parameters?["Columns"]?.intValue ?? 1)
        let rowBytes = (colors * columns * bits + 7) / 8
        guard rowBytes > 0 else { return input }
        if predictor == 2 {
            guard input.count % rowBytes == 0 else {
                throw PDFObjectError.corruptStream("TIFF predictor row length")
            }
            return tiffPredictor(input, colors: colors, bits: bits, columns: columns)
        }
        guard (10...15).contains(predictor) else {
            throw PDFObjectError.corruptStream("unsupported predictor \(predictor)")
        }
        return try pngPredictor(input, predictor: predictor,
                                rowBytes: rowBytes,
                                bytesPerPixel: max(1, (colors * bits + 7) / 8))
    }

    private static func tiffPredictor(_ input: Data, colors: Int, bits: Int, columns: Int) -> Data {
        let samplesPerRow = colors * columns
        let mask = (1 << bits) - 1
        var bitReader = SampleBitReader(bytes: Array(input), width: bits)
        var output = SampleBitWriter(width: bits)
        while bitReader.remaining >= samplesPerRow {
            var row: [Int] = []
            row.reserveCapacity(samplesPerRow)
            for index in 0..<samplesPerRow {
                var sample = bitReader.read()
                if index >= colors { sample = (sample + row[index - colors]) & mask }
                row.append(sample)
                output.append(sample)
            }
            output.finishByte()
            bitReader.finishByte()
        }
        return Data(output.bytes)
    }

    private static func pngPredictor(_ input: Data, predictor: Int,
                                     rowBytes: Int, bytesPerPixel: Int) throws -> Data {
        let encoded = Array(input)
        // PDF producers normally include a PNG filter byte on every row, even
        // for fixed predictors. Accept fixed rows without tags as a compatibility
        // path for older generators.
        let tagged = encoded.count % (rowBytes + 1) == 0
        let stride = tagged ? rowBytes + 1 : rowBytes
        guard stride > 0, encoded.count % stride == 0 else {
            throw PDFObjectError.corruptStream("PNG predictor row length")
        }
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var result = Data(capacity: (encoded.count / stride) * rowBytes)
        var offset = 0
        while offset < encoded.count {
            let filter = tagged ? Int(encoded[offset]) : predictor - 10
            let start = offset + (tagged ? 1 : 0)
            guard (0...4).contains(filter), start + rowBytes <= encoded.count else {
                throw PDFObjectError.corruptStream("invalid PNG predictor filter")
            }
            var row = [UInt8](encoded[start..<(start + rowBytes)])
            for column in 0..<rowBytes {
                let left = column >= bytesPerPixel ? row[column - bytesPerPixel] : 0
                let up = previous[column]
                let upLeft = column >= bytesPerPixel ? previous[column - bytesPerPixel] : 0
                let prediction: UInt8
                switch filter {
                case 0: prediction = 0
                case 1: prediction = left
                case 2: prediction = up
                case 3: prediction = UInt8((Int(left) + Int(up)) / 2)
                default: prediction = paeth(left, up, upLeft)
                }
                row[column] = row[column] &+ prediction
            }
            result.append(contentsOf: row)
            previous = row
            offset += stride
        }
        return result
    }

    private static func paeth(_ left: UInt8, _ up: UInt8, _ upLeft: UInt8) -> UInt8 {
        let p = Int(left) + Int(up) - Int(upLeft)
        let pa = abs(p - Int(left)), pb = abs(p - Int(up)), pc = abs(p - Int(upLeft))
        return pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
    }
}

private struct MSBBitReader {
    let bytes: [UInt8]
    var bitOffset = 0

    mutating func read(_ width: Int) -> Int? {
        guard bitOffset + width <= bytes.count * 8 else { return nil }
        var result = 0
        for _ in 0..<width {
            let byte = bytes[bitOffset / 8]
            result = (result << 1) | Int((byte >> (7 - bitOffset % 8)) & 1)
            bitOffset += 1
        }
        return result
    }
}

private struct SampleBitReader {
    let bytes: [UInt8]
    let width: Int
    var bitOffset = 0
    var remaining: Int { (bytes.count * 8 - bitOffset) / width }

    mutating func read() -> Int {
        var value = 0
        for _ in 0..<width {
            value = (value << 1) | Int((bytes[bitOffset / 8] >> (7 - bitOffset % 8)) & 1)
            bitOffset += 1
        }
        return value
    }

    mutating func finishByte() { bitOffset = (bitOffset + 7) & ~7 }
}

private struct SampleBitWriter {
    let width: Int
    var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var used = 0

    init(width: Int) { self.width = width }

    mutating func append(_ value: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> shift) & 1)
            used += 1
            if used == 8 { bytes.append(current); current = 0; used = 0 }
        }
    }

    mutating func finishByte() {
        if used > 0 { bytes.append(current << UInt8(8 - used)); current = 0; used = 0 }
    }
}
