import Foundation

/// An indirect object identifier in a PDF file.
public struct PDFObjectReference: Hashable, Sendable, CustomStringConvertible {
    public let objectNumber: Int
    public let generation: Int

    public init(_ objectNumber: Int, _ generation: Int = 0) {
        self.objectNumber = objectNumber
        self.generation = generation
    }

    public var description: String { "\(objectNumber) \(generation) R" }
}

/// A byte range in a decoded PDF stream. Unlike `Range<Data.Index>`, this is
/// stable across `Data` values and is safe to expose from the portable API.
public struct PDFByteRange: Hashable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int

    public init(_ lowerBound: Int, _ upperBound: Int) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var count: Int { upperBound - lowerBound }
    var range: Range<Int> { lowerBound..<upperBound }
}

/// The complete set of PDF object types defined by ISO 32000.
public indirect enum PDFObject: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int)
    case real(Double)
    case name(String)
    case string(Data)
    case array([PDFObject])
    case dictionary([String: PDFObject])
    case stream(PDFStream)
    case reference(PDFObjectReference)
}

/// A stream dictionary plus its exact encoded bytes.
public struct PDFStream: Sendable, Equatable {
    public var dictionary: [String: PDFObject]
    public var data: Data

    public init(dictionary: [String: PDFObject], data: Data) {
        self.dictionary = dictionary
        self.data = data
    }
}

extension PDFObject {
    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .real(let value): return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }

    var nameValue: String? {
        if case .name(let value) = self { return value }
        return nil
    }

    var arrayValue: [PDFObject]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var dictionaryValue: [String: PDFObject]? {
        switch self {
        case .dictionary(let value): return value
        case .stream(let stream): return stream.dictionary
        default: return nil
        }
    }

    var referenceValue: PDFObjectReference? {
        if case .reference(let value) = self { return value }
        return nil
    }
}

/// Typed failures produced by the syntax/object layer.
public enum PDFObjectError: Error, Equatable, LocalizedError {
    case invalidHeader
    case missingStartXRef
    case malformedObject(offset: Int, reason: String)
    case missingObject(PDFObjectReference)
    case unsupportedFilter(String)
    case corruptStream(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "The file does not have a valid PDF header."
        case .missingStartXRef:
            return "The PDF has no readable cross-reference start offset."
        case .malformedObject(let offset, let reason):
            return "Malformed PDF object near byte \(offset): \(reason)"
        case .missingObject(let reference):
            return "PDF object \(reference) could not be found."
        case .unsupportedFilter(let name):
            return "The PDF stream uses unsupported filter \(name)."
        case .corruptStream(let reason):
            return "A PDF stream is corrupt: \(reason)"
        }
    }
}
