import Foundation
import XCTest
import zlib
@testable import ReamCore

final class PDFObjectAndEditingTests: XCTestCase {
    func testObjectSyntaxCoversEveryPrimitiveAndExactStreamBytes() throws {
        let syntax = #"<< /A#20Name true /Nothing null /Integer -2 /Real .5 /Ref 7 2 R /Array [false (a\(b\)\053) <4869>] >>"#
        var parser = PDFSyntaxParser(data: Data(syntax.utf8))
        guard case .dictionary(let dictionary) = try parser.parseObject() else {
            return XCTFail("expected dictionary")
        }
        XCTAssertEqual(dictionary["A Name"], .boolean(true))
        XCTAssertEqual(dictionary["Nothing"], .null)
        XCTAssertEqual(dictionary["Integer"], .integer(-2))
        XCTAssertEqual(dictionary["Real"], .real(0.5))
        XCTAssertEqual(dictionary["Ref"], .reference(PDFObjectReference(7, 2)))
        XCTAssertEqual(dictionary["Array"]?.arrayValue,
                       [.boolean(false), .string(Data("a(b)+".utf8)), .string(Data("Hi".utf8))])

        var streamSyntax = Data("9 0 obj\n<< /Length 4 >>\nstream\n".utf8)
        let payload = Data([0x00, 0x65, 0x6E, 0x64])
        streamSyntax.append(payload)
        streamSyntax.appendASCII("\nendstream\nendobj")
        var streamParser = PDFSyntaxParser(data: streamSyntax)
        let (reference, object) = try streamParser.parseIndirectObject()
        XCTAssertEqual(reference, PDFObjectReference(9, 0))
        guard case .stream(let stream) = object else { return XCTFail("expected stream") }
        XCTAssertEqual(stream.data, payload)
    }

    func testClassicXRefEditIsPrefixPreservingAndSequentiallyReadable() throws {
        let original = PDFTestFiles.classic(content: "BT /F1 20 Tf 40 100 Td (Hello) Tj ET")
        let editor = try PDFTextEditor.open(data: original)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        XCTAssertEqual(run.text, "Hello")

        let edited = try editor.replaceText(of: run, with: "Jello")
        XCTAssertTrue(edited.starts(with: original))
        let reopened = try PDFTextEditor.open(data: edited)
        XCTAssertEqual(try reopened.textRuns(onPage: 0).first?.text, "Jello")

        let twice = try reopened.replaceText(of: try XCTUnwrap(reopened.textRuns(onPage: 0).first), with: "Hello")
        XCTAssertTrue(twice.starts(with: edited))
        XCTAssertEqual(try PDFTextEditor.open(data: twice).textRuns(onPage: 0).first?.text, "Hello")
    }

    func testNoOpDataIsByteIdentical() throws {
        let original = PDFTestFiles.classic(content: "BT /F1 12 Tf (Hello) Tj ET")
        XCTAssertEqual(try PDFTextEditor.open(data: original).unmodifiedData(), original)
    }

    func testUnencodableEditIsStructuredAndProducesNoOutput() throws {
        let editor = try PDFTextEditor.open(data: PDFTestFiles.classic(content: "BT /F1 12 Tf (Hello) Tj ET"))
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        XCTAssertThrowsError(try editor.replaceText(of: run, with: "Hello 😀")) { error in
            guard case PDFTextEditingError.unencodableCharacters(let characters, let font) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(characters, ["😀"])
            XCTAssertEqual(font, "Helvetica")
        }
    }

    func testStandardEncodingDoesNotInventUndefinedLatin1Codes() throws {
        let pdf = PDFTestFiles.classic(content: "BT /F1 12 Tf (Hello) Tj ET",
                                       font: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /StandardEncoding >>")
        let editor = try PDFTextEditor.open(data: pdf)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        XCTAssertThrowsError(try editor.replaceText(of: run, with: "©")) { error in
            guard case PDFTextEditingError.unencodableCharacters(let characters, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(characters, ["©"])
        }
    }

    func testEncryptedDocumentFailsBeforeEditing() {
        let pdf = PDFTestFiles.classic(content: "", trailerExtras: "/Encrypt 9 0 R")
        XCTAssertThrowsError(try PDFTextEditor.open(data: pdf)) {
            XCTAssertEqual($0 as? PDFTextEditingError, .encryptedDocument)
        }
    }

    func testBrokenXRefOffsetsFallBackToObjectScan() throws {
        var pdf = PDFTestFiles.classic(content: "BT /F1 12 Tf (Scan) Tj ET")
        let marker = Data("0000000015 00000 n".utf8)
        if let range = pdf.range(of: marker) {
            pdf.replaceSubrange(range, with: Data("0000000001 00000 n".utf8))
        }
        XCTAssertEqual(try PDFTextEditor.open(data: pdf).textRuns(onPage: 0).first?.text, "Scan")
    }

    func testPageTreeEnumeratesOrderAndInheritedAttributes() throws {
        let first = "BT /F1 20 Tf 40 100 Td (First) Tj ET"
        let second = "BT /F1 20 Tf 40 100 Td (Second) Tj ET"
        let pdf = PDFTestFiles.objects([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 /MediaBox [10 20 310 220] /CropBox [20 30 300 200] /Rotate 90 /Resources << /Font << /F1 4 0 R >> >> >>",
            3: "<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>",
            4: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            5: "<< /Length \(first.utf8.count) >>\nstream\n\(first)\nendstream",
            6: "<< /Type /Page /Parent 2 0 R /Contents 7 0 R >>",
            7: "<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream"
        ])
        let editor = try PDFTextEditor.open(data: pdf)
        XCTAssertEqual(editor.pageCount, 2)
        let firstRun = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        XCTAssertEqual(firstRun.text, "First")
        XCTAssertEqual(try editor.textRuns(onPage: 1).first?.text, "Second")
        XCTAssertNotEqual(firstRun.bounds, firstRun.userSpaceBounds,
                          "inherited crop/rotation must normalize displayed bounds")
    }

    func testXRefStreamAndObjectStreamEditWritesXRefStream() throws {
        let original = PDFTestFiles.xrefStreamWithCompressedPage()
        let editor = try PDFTextEditor.open(data: original)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        let edited = try editor.replaceText(of: run, with: "Jello")
        XCTAssertTrue(edited.starts(with: original))
        XCTAssertEqual(try PDFTextEditor.open(data: edited).textRuns(onPage: 0).first?.text, "Jello")
        XCTAssertTrue(String(decoding: edited.suffix(400), as: UTF8.self).contains("/Type /XRef"))
    }

    func testHybridXRefResolvesCompressedPage() throws {
        let editor = try PDFTextEditor.open(data: PDFTestFiles.hybrid())
        XCTAssertEqual(try editor.textRuns(onPage: 0).first?.text, "Hello")
    }

    func testType0IdentityAndToUnicodeCMap() throws {
        let editor = try PDFTextEditor.open(data: PDFTestFiles.type0Identity())
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first)
        XCTAssertEqual(run.text, "Hello")
        let edited = try editor.replaceText(of: run, with: "Helle")
        XCTAssertEqual(try PDFTextEditor.open(data: edited).textRuns(onPage: 0).first?.text, "Helle")
    }

    func testTokenizerSkipsInlineImagePayload() throws {
        let content = Data("q BI /W 1 /H 1 /BPC 8 /CS /G ID abc EI Q BT /F1 12 Tf (Real) Tj ET".utf8)
        let operations = try PDFContentTokenizer.operations(in: content)
        XCTAssertEqual(operations.filter { $0.name == "Tj" }.count, 1)
        XCTAssertFalse(operations.contains { $0.name == "abc" })
    }

    func testASCIIHexASCII85AndRunLengthFilters() throws {
        XCTAssertEqual(try PDFStreamFilters.decode(Data("48656c6c6f>".utf8), filters: .name("ASCIIHexDecode")), Data("Hello".utf8))
        XCTAssertEqual(try PDFStreamFilters.decode(Data("<~87cURDZ~>".utf8), filters: .name("ASCII85Decode")), Data("Hello".utf8))
        XCTAssertEqual(try PDFStreamFilters.decode(Data([2, 65, 66, 67, 254, 90, 128]), filters: .name("RunLengthDecode")), Data("ABCZZZ".utf8))
    }

    func testLZWFilter() throws {
        let source = Data("TOBEORNOTTOBEORTOBEORNOT".utf8)
        let encoded = lzwEncode(source)
        XCTAssertEqual(try PDFStreamFilters.decode(encoded, filters: .name("LZWDecode")), source)
    }

    func testFlateAndTIFFPredictorForEightAndFourBitSamples() throws {
        let predicted8 = Data([10, 10, 10, 10, 50, 10]) // rows [10,20,30], [10,60,70]
        let parameters: PDFObject = .dictionary(["Predictor": .integer(2), "Columns": .integer(3),
                                                 "Colors": .integer(1), "BitsPerComponent": .integer(8)])
        XCTAssertEqual(try PDFStreamFilters.decode(zlib(predicted8), filters: .name("FlateDecode"), parameters: parameters),
                       Data([10, 20, 30, 10, 60, 70]))

        // 4-bit row: deltas 1,1,1,1 reconstruct samples 1,2,3,4.
        let parameters4: PDFObject = .dictionary(["Predictor": .integer(2), "Columns": .integer(4),
                                                  "Colors": .integer(1), "BitsPerComponent": .integer(4)])
        XCTAssertEqual(try PDFStreamFilters.decode(zlib(Data([0x11, 0x11])), filters: .name("FlateDecode"), parameters: parameters4),
                       Data([0x12, 0x34]))
    }

    func testAllPNGPredictors() throws {
        let expected = Data([10, 20, 30, 15, 25, 40])
        let rowsByFilter: [Int: Data] = [
            0: Data([0, 10, 20, 30, 0, 15, 25, 40]),
            1: Data([1, 10, 10, 10, 1, 15, 10, 15]),
            2: Data([2, 10, 20, 30, 2, 5, 5, 10]),
            3: Data([3, 10, 15, 20, 3, 10, 8, 13]),
            4: Data([4, 10, 10, 10, 4, 5, 5, 10])
        ]
        for predictor in 10...15 {
            let filter = predictor == 15 ? 4 : predictor - 10
            let parameters: PDFObject = .dictionary(["Predictor": .integer(predictor), "Columns": .integer(3)])
            let decoded = try PDFStreamFilters.decode(zlib(rowsByFilter[filter]!),
                                                      filters: .name("FlateDecode"), parameters: parameters)
            XCTAssertEqual(decoded, expected, "predictor \(predictor)")
        }
    }

    private func zlib(_ data: Data) -> Data {
        var count = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(count))
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress!, &count,
                          source.bindMemory(to: UInt8.self).baseAddress!, uLong(data.count), Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK)
        return Data(output.prefix(Int(count)))
    }

    private func lzwEncode(_ data: Data) -> Data {
        var dictionary: [Data: Int] = Dictionary(uniqueKeysWithValues: (0..<256).map { (Data([UInt8($0)]), $0) })
        var codes = [256], next = 258
        var current = Data()
        for byte in data {
            var candidate = current; candidate.append(byte)
            if dictionary[candidate] != nil { current = candidate }
            else {
                if let code = dictionary[current] { codes.append(code) }
                if next < 4096 { dictionary[candidate] = next; next += 1 }
                current = Data([byte])
            }
        }
        if let code = dictionary[current] { codes.append(code) }
        codes.append(257)
        // This fixture remains in the 9-bit range.
        var result = Data(), accumulator = 0, bits = 0
        for code in codes {
            accumulator = (accumulator << 9) | code; bits += 9
            while bits >= 8 {
                result.append(UInt8((accumulator >> (bits - 8)) & 0xFF)); bits -= 8
            }
        }
        if bits > 0 { result.append(UInt8((accumulator << (8 - bits)) & 0xFF)) }
        return result
    }
}

private enum PDFTestFiles {
    static func classic(content: String, trailerExtras: String = "",
                        font: String = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>") -> Data {
        objects([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            4: font,
            5: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ], trailerExtras: trailerExtras)
    }

    static func objects(_ objects: [Int: String], trailerExtras: String = "") -> Data {
        var output = Data("%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8), offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = output.count
            output.appendASCII("\(number) 0 obj\n\(objects[number]!)\nendobj\n")
        }
        let xref = output.count, size = (objects.keys.max() ?? 0) + 1
        output.appendASCII("xref\n0 \(size)\n0000000000 65535 f \n")
        for number in 1..<size {
            if let offset = offsets[number] { output.appendASCII(String(format: "%010d 00000 n \n", offset)) }
            else { output.appendASCII("0000000000 00000 f \n") }
        }
        output.appendASCII("trailer\n<< /Size \(size) /Root 1 0 R \(trailerExtras) >>\nstartxref\n\(xref)\n%%EOF\n")
        return output
    }

    static func xrefStreamWithCompressedPage() -> Data {
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        let objectStreamBody = "3 0 \(page)"
        let content = "BT /F1 20 Tf 40 100 Td (Hello) Tj ET"
        var output = Data("%PDF-1.5\n".utf8), offsets: [Int: Int] = [:]
        func append(_ number: Int, _ body: String) {
            offsets[number] = output.count
            output.appendASCII("\(number) 0 obj\n\(body)\nendobj\n")
        }
        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        append(5, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        append(6, "<< /Type /ObjStm /N 1 /First 4 /Length \(objectStreamBody.utf8.count) >>\nstream\n\(objectStreamBody)\nendstream")
        let xrefOffset = output.count
        var rows = Data()
        for number in 0...7 {
            if number == 0 { rows.append(0); rows.append(contentsOf: [0,0,0,0,0xFF,0xFF]) }
            else if number == 3 { rows.append(2); rows.append(contentsOf: [0,0,0,6,0,0]) }
            else {
                let offset = number == 7 ? xrefOffset : offsets[number] ?? 0
                rows.append(1)
                rows.append(contentsOf: [UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF),
                                         UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), 0, 0])
            }
        }
        // Exercise /Index and the normal Flate + PNG-Up encoding used by
        // production xref streams, not just the raw-row compatibility path.
        let predicted = pngUp(rows, columns: 7)
        let compressed = deflate(predicted)
        output.appendASCII("7 0 obj\n<< /Type /XRef /Size 8 /Root 1 0 R /W [1 4 2] /Index [0 8] /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 7 /Colors 1 /BitsPerComponent 8 >> /Length \(compressed.count) >>\nstream\n")
        output.append(compressed)
        output.appendASCII("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n")
        return output
    }

    private static func pngUp(_ data: Data, columns: Int) -> Data {
        precondition(columns > 0 && data.count.isMultiple(of: columns))
        var output = Data(), previous = [UInt8](repeating: 0, count: columns)
        let bytes = Array(data)
        for start in stride(from: 0, to: bytes.count, by: columns) {
            output.append(2)
            let row = Array(bytes[start..<(start + columns)])
            for column in 0..<columns { output.append(row[column] &- previous[column]) }
            previous = row
        }
        return output
    }

    private static func deflate(_ data: Data) -> Data {
        var count = compressBound(uLong(data.count))
        var output = [UInt8](repeating: 0, count: Int(count))
        let status = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(destination.bindMemory(to: UInt8.self).baseAddress!, &count,
                          source.bindMemory(to: UInt8.self).baseAddress!, uLong(data.count), Z_BEST_SPEED)
            }
        }
        precondition(status == Z_OK)
        return Data(output.prefix(Int(count)))
    }

    static func hybrid() -> Data {
        let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        let body = "3 0 \(page)"
        let content = "BT /F1 20 Tf 40 100 Td (Hello) Tj ET"
        var output = Data("%PDF-1.5\n".utf8), offsets: [Int: Int] = [:]
        func append(_ number: Int, _ object: String) {
            offsets[number] = output.count
            output.appendASCII("\(number) 0 obj\n\(object)\nendobj\n")
        }
        append(1, "<< /Type /Catalog /Pages 2 0 R >>")
        append(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        append(4, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        append(5, "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        append(6, "<< /Type /ObjStm /N 1 /First 4 /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
        let hybridOffset = output.count
        append(7, "<< /Type /XRef /Size 8 /W [1 4 2] /Index [3 1] /Length 7 >>\nstream\n\u{02}\u{00}\u{00}\u{00}\u{06}\u{00}\u{00}\nendstream")
        let xref = output.count
        output.appendASCII("xref\n0 8\n0000000000 65535 f \n")
        for number in 1...7 {
            if number == 3 { output.appendASCII("0000000000 00000 f \n") }
            else { output.appendASCII(String(format: "%010d 00000 n \n", offsets[number]!)) }
        }
        output.appendASCII("trailer\n<< /Size 8 /Root 1 0 R /XRefStm \(hybridOffset) >>\nstartxref\n\(xref)\n%%EOF\n")
        return output
    }

    static func type0Identity() -> Data {
        let cmap = "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Test def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n5 beginbfchar\n<0048> <0048>\n<0065> <0065>\n<006C> <006C>\n<006F> <006F>\n<0020> <0020>\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend end"
        let content = "BT /F1 20 Tf 40 100 Td <00480065006C006C006F> Tj ET"
        return objects([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            4: "<< /Type /Font /Subtype /Type0 /BaseFont /Test /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 6 0 R >>",
            5: "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            6: "<< /Length \(cmap.utf8.count) >>\nstream\n\(cmap)\nendstream",
            7: "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Test /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 600 /W [72 [600] 101 [600] 108 [600] 111 [600]] /CIDToGIDMap /Identity >>"
        ])
    }
}
