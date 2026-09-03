import AppKit
import CoreText
import Foundation

/// PDFs generated at test time so the fidelity suite does not depend on opaque
/// golden binaries (apart from the long-standing sample.pdf smoke fixture).
enum PDFEditingFixtures {
    struct Fixture {
        let name: String
        let data: Data
        let oldText: String
        let newText: String
    }

    static func corpus() -> [Fixture] {
        [
            Fixture(name: "standard14-winansi", data: classic(contents: ["BT /F1 24 Tf 50 100 Td (Hello) Tj ET"]), oldText: "Hello", newText: "Helle"),
            simpleTrueTypeDifferences(),
            type1DifferencesMinus(),
            Fixture(name: "tj-kerning", data: classic(contents: ["BT /F1 24 Tf 50 100 Td [(Hello) -80 ( World)] TJ ET"]), oldText: "Hello", newText: "Helle"),
            Fixture(name: "multiple-contents", data: classic(contents: ["q 1 0 0 1 0 0 cm", "BT /F1 24 Tf 50 100 Td (Hello) Tj ET Q"]), oldText: "Hello", newText: "Helle"),
            Fixture(name: "rotated", data: classic(contents: ["BT /F1 24 Tf 50 100 Td (Hello) Tj ET"], pageExtras: "/Rotate 90"), oldText: "Hello", newText: "Helle"),
            Fixture(name: "crop-origin", data: classic(contents: ["BT /F1 24 Tf 50 100 Td (Hello) Tj ET"],
                mediaBox: "[10 20 310 220]", pageExtras: "/CropBox [20 30 300 200]"), oldText: "Hello", newText: "Helle"),
            Fixture(name: "xref-stream", data: xrefStream(), oldText: "Hello", newText: "Helle")
        ]
    }

    /// CoreGraphics emits a real embedded system-font subset (the concrete
    /// simple-vs-Type0 representation varies by macOS release). ReamCore's
    /// headless corpus separately pins Type0/Identity-H and ToUnicode behavior.
    static func coreGraphicsType0() -> Fixture? {
        let mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = mediaBox
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: "Hello", attributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
        ]).draw(at: CGPoint(x: 50, y: 90))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        return Fixture(name: "coregraphics-type0", data: data as Data, oldText: "Hello", newText: "Helle")
    }

    /// A structurally valid simple TrueType font with a /Differences encoding.
    /// The system font bytes are embedded into the generated fixture, keeping
    /// both glyph selection and widths meaningful to independent PDF renderers.
    private static func simpleTrueTypeDifferences() -> Fixture {
        let font = NSFont(name: "Arial", size: 24) ?? NSFont.systemFont(ofSize: 24)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              let fontData = try? Data(contentsOf: url) else {
            preconditionFailure("The macOS test host did not expose its system TrueType font")
        }
        let content = Data("BT /F1 24 Tf 50 100 Td (ABCCD) Tj ET".utf8)
        let objects: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2: Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 7 0 R >>".utf8),
            4: Data("<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+ArialMT /FirstChar 65 /LastChar 68 /Widths [722 556 222 556] /FontDescriptor 5 0 R /Encoding << /BaseEncoding /WinAnsiEncoding /Differences [65 /uni0048 66 /uni0065 67 /uni006C 68 /uni006F] >> >>".utf8),
            5: Data("<< /Type /FontDescriptor /FontName /ABCDEF+ArialMT /Flags 32 /FontBBox [-665 -325 2000 1040] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /MissingWidth 500 /FontFile2 6 0 R >>".utf8),
            6: stream(fontData, extra: "/Length1 \(fontData.count)"),
            7: stream(content)
        ]
        return Fixture(name: "truetype-differences", data: classicObjects(objects),
                       oldText: "Hello", newText: "Helle")
    }

    /// A non-embedded standard-14 Times-Bold whose indirect /Encoding remaps
    /// code 173 to /minus, mirroring font object 9 of
    /// `/usr/share/doc/bash/article.pdf` (Ghostscript output) including its
    /// 256-entry /Widths array. PDFKit extracts U+2212 there, so the shared
    /// oracle pins the same decoding, the byte prefix, and the encoder's
    /// round-trip of U+2212 back to code 173.
    private static func type1DifferencesMinus() -> Fixture {
        let content = Data("BT /F1 18 Tf 20 100 Td (Bash \\255 The GNU shell) Tj ET".utf8)
        let objects: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2: Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".utf8),
            4: Data("<</Subtype/Type1/BaseFont/Times-Bold/Type/Font/Name/R9/FirstChar 0/LastChar 255/Widths[\n\(articleTimesBoldWidths)]\n/Encoding 6 0 R>>".utf8),
            5: stream(content),
            6: Data("<</Type/Encoding/Differences[\n173/minus]>>".utf8)
        ]
        return Fixture(name: "type1-differences-minus", data: classicObjects(objects),
                       oldText: "Bash \u{2212} The GNU shell", newText: "Bash \u{2212} the GNU shell")
    }

    private static let articleTimesBoldWidths = """
581 520 556 667 389 444 722 1000 278 250 250 250 250 250 250 250
250 250 250 250 250 250 250 250 250 250 250 250 250 250 250 250
250 333 555 500 500 1000 833 333 333 333 500 570 250 333 250 278
500 500 500 500 500 500 500 500 500 500 333 333 570 570 570 500
930 722 667 722 722 667 611 778 778 389 500 778 667 944 722 778
611 778 722 556 667 722 722 1000 722 722 667 333 278 333 333 500
333 500 556 444 556 444 333 500 556 278 333 556 278 833 556 500
556 556 444 389 333 556 500 722 500 500 444 394 220 394 333 250
333 500 500 350 500 167 1000 500 500 500 1000 250 556 556 250 250
278 250 333 333 333 333 333 333 333 500 500 722 278 500 1000 667
250 333 500 500 500 500 220 500 333 747 300 333 570 570 747 333
400 570 300 300 333 556 540 250 333 300 330 333 750 750 750 500
722 722 722 722 722 722 1000 722 667 667 667 667 389 389 389 389
722 722 778 778 778 778 778 570 778 722 722 722 722 722 611 556
500 500 500 500 500 500 722 444 444 444 444 444 278 278 278 278
500 556 500 500 500 500 500 570 500 556 556 556 556 500 556 500
"""

    private static func classic(contents: [String],
                                font: String = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
                                mediaBox: String = "[0 0 300 200]", pageExtras: String = "") -> Data {
        let contentRefs = contents.indices.map { "\(5 + $0) 0 R" }
        let contentsValue = contents.count == 1 ? contentRefs[0] : "[\(contentRefs.joined(separator: " "))]"
        var objects: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2: Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox \(mediaBox) \(pageExtras) /Resources << /Font << /F1 4 0 R >> >> /Contents \(contentsValue) >>".utf8),
            4: Data(font.utf8)
        ]
        for (index, content) in contents.enumerated() {
            objects[5 + index] = stream(Data(content.utf8))
        }
        return classicObjects(objects)
    }

    private static func xrefStream() -> Data {
        let content = Data("BT /F1 24 Tf 50 100 Td (Hello) Tj ET".utf8)
        let objects: [Int: Data] = [
            1: Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            2: Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            3: Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>".utf8),
            4: Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>".utf8),
            5: stream(content)
        ]
        var output = Data("%PDF-1.5\n".utf8), offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = output.count; appendObject(number, objects[number]!, to: &output)
        }
        let xrefOffset = output.count
        var rows = Data()
        for number in 0...6 {
            if number == 0 { rows.append(contentsOf: [0, 0, 0, 0, 0, 0xFF, 0xFF]) }
            else {
                let offset = number == 6 ? xrefOffset : offsets[number]!
                rows.append(1); rows.append(contentsOf: [UInt8((offset >> 24) & 0xFF), UInt8((offset >> 16) & 0xFF), UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), 0, 0])
            }
        }
        appendObject(6, stream(rows, extra: "/Type /XRef /Size 7 /Root 1 0 R /W [1 4 2]"), to: &output)
        output.appendText("startxref\n\(xrefOffset)\n%%EOF\n")
        return output
    }

    private static func classicObjects(_ objects: [Int: Data]) -> Data {
        var output = Data("%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8), offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = output.count; appendObject(number, objects[number]!, to: &output)
        }
        let xref = output.count, size = objects.keys.max()! + 1
        output.appendText("xref\n0 \(size)\n0000000000 65535 f \n")
        for number in 1..<size {
            output.appendText(offsets[number].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 00000 f \n")
        }
        output.appendText("trailer\n<< /Size \(size) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n")
        return output
    }

    private static func stream(_ data: Data, extra: String = "") -> Data {
        var result = Data("<< \(extra) /Length \(data.count) >>\nstream\n".utf8)
        result.append(data); result.appendText("\nendstream")
        return result
    }

    private static func appendObject(_ number: Int, _ body: Data, to output: inout Data) {
        output.appendText("\(number) 0 obj\n"); output.append(body); output.appendText("\nendobj\n")
    }
}

private extension Data {
    mutating func appendText(_ value: String) { append(contentsOf: value.utf8) }
}
