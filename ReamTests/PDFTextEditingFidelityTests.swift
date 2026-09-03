import AppKit
import PDFKit
import ReamCore
import XCTest
@testable import Ream

final class PDFTextEditingFidelityTests: XCTestCase {
    func testGeneratedCorpusPreservesPrefixPixelsExtractionAndValidity() throws {
        for fixture in PDFEditingFixtures.corpus() {
            try assertFidelity(fixture)
        }
    }

    func testCoreGraphicsEmbeddedSubsetVerticalSlice() throws {
        let fixture = try XCTUnwrap(PDFEditingFixtures.coreGraphicsType0())
        try assertFidelity(fixture)
    }

    func testBundledSampleNoOpIsByteIdentical() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "sample", withExtension: "pdf"))
        let original = try Data(contentsOf: url)
        XCTAssertEqual(try PDFTextEditor.open(data: original).unmodifiedData(), original)
        XCTAssertEqual(try PDFReferenceDocument(data: original).snapshot(contentType: .pdf), original)
    }

    func testBundledSampleEditPreservesPrefixPixelsExtractionAndValidity() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "sample", withExtension: "pdf"))
        let original = try Data(contentsOf: url)
        try assertFidelity(.init(name: "bundled-sample", data: original,
                                 oldText: "Re", newText: "eR"))
    }

    func testEmbeddedSubsetRejectsGlyphMissingFromItsCMap() throws {
        let fixture = try XCTUnwrap(PDFEditingFixtures.coreGraphicsType0())
        let editor = try PDFTextEditor.open(data: fixture.data)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first { $0.text == fixture.oldText })
        XCTAssertThrowsError(try editor.replaceText(of: run, with: "Helloz")) { error in
            guard case PDFTextEditingError.unencodableCharacters(let characters, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(characters, ["z"])
        }
    }

    func testDocumentSnapshotReturnsIncrementalBytesVerbatimAndUndoRestores() throws {
        let fixture = PDFEditingFixtures.corpus()[0]
        let editor = try PDFTextEditor.open(data: fixture.data)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first { $0.text == fixture.oldText })
        let edited = try editor.replaceText(of: run, with: fixture.newText)
        let model = PDFReferenceDocument()
        let undo = UndoManager()
        try model.applyTextEditData(edited, undoManager: undo)
        XCTAssertEqual(try model.snapshot(contentType: .pdf), edited)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertNotEqual(try model.snapshot(contentType: .pdf), edited)
        undo.redo()
        XCTAssertEqual(try model.snapshot(contentType: .pdf), edited)
    }

    func testMixedPDFKitMutationReserializesWithoutLosingTextEdit() throws {
        let fixture = PDFEditingFixtures.corpus()[0]
        let editor = try PDFTextEditor.open(data: fixture.data)
        let run = try XCTUnwrap(editor.textRuns(onPage: 0).first { $0.text == fixture.oldText })
        let edited = try editor.replaceText(of: run, with: fixture.newText)
        let model = PDFReferenceDocument()
        try model.applyTextEditData(edited, undoManager: nil)
        model.updateMetadata(.init(title: "Mixed mutation"), undoManager: nil)

        let snapshot = try model.snapshot(contentType: .pdf)
        XCTAssertNotEqual(snapshot, edited, "PDFKit-level mutations intentionally leave the byte-stable save path")
        let reopened = try XCTUnwrap(PDFDocument(data: snapshot))
        XCTAssertTrue((reopened.page(at: 0)?.string ?? "").contains(fixture.newText))
        XCTAssertEqual(reopened.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       "Mixed mutation")
    }

    private func assertFidelity(_ fixture: PDFEditingFixtures.Fixture,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = try PDFTextEditor.open(data: fixture.data)
        let runs = try editor.textRuns(onPage: 0)
        let run = try XCTUnwrap(runs.first { $0.text == fixture.oldText },
                                "missing run in \(fixture.name); decoded \(runs.map(\.text))", file: file, line: line)
        let before = try render(fixture.data)
        let edited = try editor.replaceText(of: run, with: fixture.newText)
        XCTAssertTrue(edited.starts(with: fixture.data), "byte prefix: \(fixture.name)", file: file, line: line)

        let pdfKit = try XCTUnwrap(PDFDocument(data: edited), fixture.name, file: file, line: line)
        let extracted = pdfKit.page(at: 0)?.string ?? ""
        XCTAssertTrue(extracted.contains(fixture.newText), "new extraction: \(fixture.name): \(extracted)", file: file, line: line)
        XCTAssertFalse(extracted.contains(fixture.oldText), "old extraction: \(fixture.name)", file: file, line: line)
        XCTAssertNotNil(CGDataProvider(data: edited as CFData).flatMap { CGPDFDocument($0) }, "CGPDFDocument: \(fixture.name)", file: file, line: line)

        let after = try render(edited)
        XCTAssertEqual(before.width, after.width)
        XCTAssertEqual(before.height, after.height)
        let kitDocument = PDFDocument(data: fixture.data)
        let kitBounds = kitDocument?.findString(fixture.oldText, withOptions: [])
            .first.flatMap { selection in kitDocument?.page(at: 0).map { selection.bounds(for: $0) } }
        if let kitBounds {
            XCTAssertEqual(run.userSpaceBounds.x, kitBounds.minX, accuracy: 1.5, fixture.name)
            XCTAssertEqual(run.userSpaceBounds.y, kitBounds.minY, accuracy: 1.5, fixture.name)
            XCTAssertEqual(run.userSpaceBounds.width, kitBounds.width, accuracy: 1.5, fixture.name)
            XCTAssertEqual(run.userSpaceBounds.height, kitBounds.height, accuracy: 1.5, fixture.name)
        }
        let sourceCGPage = try XCTUnwrap(CGDataProvider(data: fixture.data as CFData)
            .flatMap { CGPDFDocument($0) }?.page(at: 1))
        let mask = pixelMask(for: kitBounds ?? CGRect(x: run.bounds.x, y: run.bounds.y,
                                                       width: run.bounds.width, height: run.bounds.height),
                             width: before.width, height: before.height, page: sourceCGPage)
        var outsideDifferences = 0
        var differenceBounds = CGRect.null
        for index in stride(from: 0, to: before.bytes.count, by: 4) where before.bytes[index..<(index + 4)] != after.bytes[index..<(index + 4)] {
            let pixel = index / 4, x = pixel % before.width, y = before.height - 1 - pixel / before.width
            differenceBounds = differenceBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            if !mask.contains(CGPoint(x: x, y: y)) { outsideDifferences += 1 }
        }
        XCTAssertEqual(outsideDifferences, 0, "pixel changes outside edited run: \(fixture.name); run=\(run.bounds) kit=\(String(describing: kitBounds)) mask=\(mask) diff=\(differenceBounds)", file: file, line: line)
    }

    private func render(_ data: Data) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let document = try XCTUnwrap(CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) })
        let page = try XCTUnwrap(document.page(at: 1))
        let width = 600, height = 400
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: colorSpace,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let transform = page.getDrawingTransform(.cropBox,
                                                     rect: CGRect(x: 0, y: 0, width: width, height: height),
                                                     rotate: 0, preserveAspectRatio: true)
            context.concatenate(transform); context.drawPDFPage(page)
        }
        return (bytes, width, height)
    }

    private func pixelMask(for rect: CGRect, width: Int, height: Int, page: CGPDFPage) -> CGRect {
        let destination = CGRect(x: 0, y: 0, width: width, height: height)
        let transform = page.getDrawingTransform(.cropBox, rect: destination,
                                                 rotate: 0, preserveAspectRatio: true)
        // PDFKit selections describe advances/ascent/descent, while rasterized
        // TrueType outlines and antialiasing can extend a few pixels into a
        // side-bearing. Keep a small device-pixel halo around the selected run;
        // every pixel outside it is still required to remain byte-for-byte RGBA
        // identical.
        return rect.applying(transform).standardized.insetBy(dx: -14, dy: -14)
    }
}
