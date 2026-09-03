import Foundation

/// Failures that leave the input PDF wholly unchanged.
public enum PDFTextEditingError: Error, Equatable, LocalizedError {
    case encryptedDocument
    case pageOutOfRange(Int)
    case runNotFound(String)
    case noTextOnPage(Int)
    case unencodableCharacters(characters: [String], fontName: String)
    case damagedContent(String)

    public var errorDescription: String? {
        switch self {
        case .encryptedDocument:
            return "This PDF is encrypted, so Ream cannot safely edit its text in place yet. Remove the password first."
        case .pageOutOfRange(let page): return "Page \(page + 1) does not exist."
        case .runNotFound: return "The selected text run is no longer present. Please select it again."
        case .noTextOnPage(let page): return "Page \(page + 1) has no editable text layer; it may be scanned or flattened."
        case .unencodableCharacters(let characters, let font):
            return "The original font “\(font)” cannot encode: \(characters.joined(separator: ", ")). Nothing was changed."
        case .damagedContent(let reason): return "The text edit could not be written safely: \(reason)"
        }
    }
}

/// Opens a PDF as immutable original bytes plus parsed object state and appends
/// surgical incremental updates for text replacements.
public final class PDFTextEditor {
    public let data: Data
    public var pageCount: Int { pages.count }

    private let document: PDFParsedDocument
    private let pages: [PDFPageInfo]
    private let layout: PDFTextLayoutEngine
    private var runsByPage: [[PDFTextRun]]

    /// Parse `data`, including every prior incremental update. Encrypted files
    /// fail immediately with a typed error before any editing state is created.
    public static func open(data: Data) throws -> PDFTextEditor {
        try PDFTextEditor(data: data)
    }

    private init(data: Data) throws {
        let parsed = try PDFParsedDocument(data: data)
        if parsed.trailer["Encrypt"] != nil { throw PDFTextEditingError.encryptedDocument }
        let pages = try parsed.pages()
        let layout = PDFTextLayoutEngine(document: parsed)
        var allRuns: [[PDFTextRun]] = []
        allRuns.reserveCapacity(pages.count)
        // Decode the whole document once so subset fonts without an inspectable
        // cmap know every code actually used with the shared font resource.
        for page in pages { allRuns.append(try layout.runs(on: page)) }
        self.data = data
        self.document = parsed
        self.pages = pages
        self.layout = layout
        self.runsByPage = allRuns
    }

    /// Editable string operands on one page, in content-stream order.
    public func textRuns(onPage pageIndex: Int) throws -> [PDFTextRun] {
        guard runsByPage.indices.contains(pageIndex) else { throw PDFTextEditingError.pageOutOfRange(pageIndex) }
        return runsByPage[pageIndex]
    }

    /// Return the source bytes verbatim. This is the no-op save seam.
    public func unmodifiedData() -> Data { data }

    /// The page's decoded /Contents bytes in their logical concatenation order.
    /// This is useful to audit that an incremental edit changed only the chosen
    /// operand; it never normalizes or reserializes content syntax.
    public func decodedPageContent(onPage pageIndex: Int) throws -> Data {
        guard pages.indices.contains(pageIndex) else { throw PDFTextEditingError.pageOutOfRange(pageIndex) }
        var result = Data()
        for content in pages[pageIndex].contents {
            result.append(try PDFStreamFilters.decode(content.stream))
        }
        return result
    }

    /// Replace exactly one string operand and append a new content stream, page
    /// dictionary and same-style xref section. The returned `Data` always begins
    /// with every byte of the input. No output is produced when validation fails.
    public func replaceText(of run: PDFTextRun, with replacement: String) throws -> Data {
        guard pages.indices.contains(run.pageIndex) else { throw PDFTextEditingError.pageOutOfRange(run.pageIndex) }
        guard let current = runsByPage[run.pageIndex].first(where: { $0.id == run.id }), current == run,
              let font = layout.font(forRunID: run.id) else {
            throw PDFTextEditingError.runNotFound(run.id)
        }
        let encoded = font.encode(replacement)
        guard let replacementBytes = encoded.data else {
            throw PDFTextEditingError.unencodableCharacters(characters: encoded.missing,
                                                             fontName: run.fontName)
        }
        let syntax = run.operandWasHex ? hexString(replacementBytes) : literalString(replacementBytes)
        let page = pages[run.pageIndex]
        var editedStreams: [Int: (PDFPageContent, Data)] = [:]
        for (segmentIndex, segment) in run.operandSegments.enumerated() {
            guard let content = page.contents.first(where: { $0.arrayIndex == segment.contentIndex }) else {
                throw PDFTextEditingError.damagedContent("the source content stream is missing")
            }
            var decoded: Data
            if let alreadyEdited = editedStreams[segment.contentIndex]?.1 {
                decoded = alreadyEdited
            } else {
                decoded = try PDFStreamFilters.decode(content.stream)
            }
            guard segment.byteRange.lowerBound >= 0,
                  segment.byteRange.upperBound <= decoded.count else {
                throw PDFTextEditingError.damagedContent("the source operand range is invalid")
            }
            decoded.replaceSubrange(segment.byteRange.range,
                                    with: segmentIndex == 0 ? syntax : Data())
            editedStreams[segment.contentIndex] = (content, decoded)
        }
        guard !editedStreams.isEmpty else {
            throw PDFTextEditingError.damagedContent("the source operand has no content-stream bytes")
        }

        let ordered = editedStreams.values.sorted { $0.0.arrayIndex < $1.0.arrayIndex }
        let updates: [(reference: PDFObjectReference, object: PDFObject, contentIndex: Int)] =
            ordered.enumerated().map { offset, item in
                var dictionary = item.0.stream.dictionary
                for key in ["Filter", "F", "DecodeParms", "DP", "Length"] { dictionary.removeValue(forKey: key) }
                return (PDFObjectReference(document.size + offset, 0),
                        .stream(PDFStream(dictionary: dictionary, data: item.1)),
                        item.0.arrayIndex)
            }
        let replacements = Dictionary(uniqueKeysWithValues: updates.map { ($0.contentIndex, $0.reference) })
        var pageDictionary = page.dictionary
        pageDictionary["Contents"] = try replacingContents(on: page, replacements: replacements)
        return writeIncremental(contents: updates.map { ($0.reference, $0.object) },
                                page: page, pageDictionary: pageDictionary)
    }

    private func replacingContents(on page: PDFPageInfo,
                                   replacements: [Int: PDFObjectReference]) throws -> PDFObject {
        guard let original = page.dictionary["Contents"] else {
            guard let replacement = replacements[0] else {
                throw PDFTextEditingError.damagedContent("the page has no replaceable content")
            }
            return .reference(replacement)
        }
        if let array = try document.dereference(original)?.arrayValue {
            var copy = array
            for (index, replacement) in replacements {
                guard copy.indices.contains(index) else {
                    throw PDFTextEditingError.damagedContent("the /Contents array changed")
                }
                copy[index] = .reference(replacement)
            }
            return .array(copy)
        }
        guard replacements.count == 1, let replacement = replacements[0] else {
            throw PDFTextEditingError.damagedContent("a single /Contents stream has inconsistent segments")
        }
        return .reference(replacement)
    }

    private func writeIncremental(contents: [(PDFObjectReference, PDFObject)],
                                  page: PDFPageInfo,
                                  pageDictionary: [String: PDFObject]) -> Data {
        var output = data
        if let last = output.last, last != 0x0A, last != 0x0D { output.append(0x0A) }
        var writtenEntries: [(Int, Int, Int)] = []
        for (reference, content) in contents {
            let offset = output.count
            appendIndirect(reference, object: content, to: &output)
            writtenEntries.append((reference.objectNumber, offset, reference.generation))
        }
        let pageOffset = output.count
        appendIndirect(page.reference, object: .dictionary(pageDictionary), to: &output)
        writtenEntries.append((page.reference.objectNumber, pageOffset, page.reference.generation))

        let nextObjectNumber = (contents.map { $0.0.objectNumber }.max() ?? (document.size - 1)) + 1
        if document.needsFullXRefRepair {
            let xrefOffset = output.count
            appendRepairedClassicXRef(updates: writtenEntries, size: nextObjectNumber, to: &output)
            output.appendASCII("startxref\n\(xrefOffset)\n%%EOF\n")
            return output
        }

        switch document.xrefStyle {
        case .table:
            let xrefOffset = output.count
            appendClassicXRef(entries: writtenEntries, size: nextObjectNumber, to: &output)
            output.appendASCII("startxref\n\(xrefOffset)\n%%EOF\n")
        case .stream:
            let xrefReference = PDFObjectReference(nextObjectNumber, 0)
            let xrefOffset = output.count
            writtenEntries.append((xrefReference.objectNumber, xrefOffset, 0))
            appendXRefStream(entries: writtenEntries, reference: xrefReference,
                             size: xrefReference.objectNumber + 1, to: &output)
            output.appendASCII("startxref\n\(xrefOffset)\n%%EOF\n")
        }
        return output
    }

    private func appendIndirect(_ reference: PDFObjectReference, object: PDFObject, to output: inout Data) {
        output.appendASCII("\(reference.objectNumber) \(reference.generation) obj\n")
        output.append(PDFObjectSerializer.data(for: object))
        output.appendASCII("\nendobj\n")
    }

    private func appendClassicXRef(entries: [(Int, Int, Int)], size: Int, to output: inout Data) {
        output.appendASCII("xref\n")
        for group in contiguous(entries.sorted { $0.0 < $1.0 }) {
            output.appendASCII("\(group[0].0) \(group.count)\n")
            for (_, offset, generation) in group {
                output.appendASCII(String(format: "%010d %05d n \n", offset, generation))
            }
        }
        output.appendASCII("trailer\n")
        output.append(PDFObjectSerializer.data(for: .dictionary(trailerDictionary(size: size))))
        output.append(0x0A)
    }

    private func appendRepairedClassicXRef(updates: [(Int, Int, Int)], size: Int, to output: inout Data) {
        var complete = document.reconstructedEntries
        for (number, offset, generation) in updates {
            complete[number] = (offset, generation)
        }
        output.appendASCII("xref\n0 \(size)\n0000000000 65535 f \n")
        if size > 1 {
            for number in 1..<size {
                if let entry = complete[number] {
                    output.appendASCII(String(format: "%010d %05d n \n", entry.offset, entry.generation))
                } else {
                    output.appendASCII("0000000000 00000 f \n")
                }
            }
        }
        output.appendASCII("trailer\n")
        output.append(PDFObjectSerializer.data(for: .dictionary(trailerDictionary(size: size,
                                                                                   includePrevious: false))))
        output.append(0x0A)
    }

    private func appendXRefStream(entries: [(Int, Int, Int)], reference: PDFObjectReference,
                                  size: Int, to output: inout Data) {
        let sorted = entries.sorted { $0.0 < $1.0 }
        let groups = contiguous(sorted)
        var index: [PDFObject] = []
        var rows = Data()
        for group in groups {
            index.append(.integer(group[0].0)); index.append(.integer(group.count))
            for (_, offset, generation) in group {
                rows.append(1); appendBigEndian(offset, width: 8, to: &rows)
                appendBigEndian(generation, width: 2, to: &rows)
            }
        }
        var dictionary = trailerDictionary(size: size)
        dictionary["Type"] = .name("XRef")
        dictionary["W"] = .array([.integer(1), .integer(8), .integer(2)])
        dictionary["Index"] = .array(index)
        appendIndirect(reference, object: .stream(PDFStream(dictionary: dictionary, data: rows)), to: &output)
    }

    private func trailerDictionary(size: Int, includePrevious: Bool = true) -> [String: PDFObject] {
        var result: [String: PDFObject] = ["Size": .integer(size)]
        for key in ["Root", "Info", "ID"] { if let value = document.trailer[key] { result[key] = value } }
        if includePrevious, document.latestXRefOffset > 0 {
            result["Prev"] = .integer(document.latestXRefOffset)
        }
        return result
    }

    private func contiguous(_ entries: [(Int, Int, Int)]) -> [[(Int, Int, Int)]] {
        var groups: [[(Int, Int, Int)]] = []
        for entry in entries {
            if let last = groups.last?.last, entry.0 == last.0 + 1 { groups[groups.count - 1].append(entry) }
            else { groups.append([entry]) }
        }
        return groups
    }

    private func appendBigEndian(_ value: Int, width: Int, to data: inout Data) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) { data.append(UInt8((value >> shift) & 0xFF)) }
    }

    private func hexString(_ data: Data) -> Data {
        var result = Data([0x3C])
        result.appendASCII(data.map { String(format: "%02X", $0) }.joined())
        result.append(0x3E)
        return result
    }

    private func literalString(_ data: Data) -> Data {
        var result = Data([0x28])
        for byte in data {
            switch byte {
            case 0x28, 0x29, 0x5C: result.append(0x5C); result.append(byte)
            case 0x0A: result.appendASCII("\\n")
            case 0x0D: result.appendASCII("\\r")
            case 0x09: result.appendASCII("\\t")
            case 0x08: result.appendASCII("\\b")
            case 0x0C: result.appendASCII("\\f")
            case 0x00...0x1F, 0x7F...0xFF: result.appendASCII(String(format: "\\%03o", byte))
            default: result.append(byte)
            }
        }
        result.append(0x29)
        return result
    }
}
