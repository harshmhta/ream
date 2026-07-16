import XCTest
import PDFKit
import AppKit
@testable import Ream

/// The brief's golden path, exercised end-to-end against the real bundled
/// sample PDF through the production annotation code:
///
///   highlight real text → add sticky note → draw ink → drop a stamp →
///   export XFDF → re-import into a copy → verify.
///
/// Unlike the synthetic-page round-trip test, this uses `selectionForRange` on
/// an actual text page so the markup path (quad points from real glyph bounds)
/// is covered.
final class GoldenPathTests: XCTestCase {

    private func sampleDocument() throws -> PDFDocument {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "sample", withExtension: "pdf") else {
            throw XCTSkip("sample.pdf fixture not found")
        }
        let doc = try XCTUnwrap(PDFDocument(url: url))
        doc.delegate = AnnotationDocumentDelegate.shared
        return doc
    }

    private func listable(_ doc: PDFDocument) -> [PDFAnnotation] {
        (0..<doc.pageCount).flatMap { doc.page(at: $0)?.annotations.filter { $0.isReamListable } ?? [] }
    }

    func testGoldenPath() throws {
        let doc = try sampleDocument()
        XCTAssertGreaterThan(doc.pageCount, 0)
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertGreaterThan(page.numberOfCharacters, 0, "sample must contain selectable text")

        // 1) Highlight real text — select the first ~20 characters.
        let range = NSRange(location: 0, length: min(20, page.numberOfCharacters))
        let selection = try XCTUnwrap(page.selection(for: range))
        XCTAssertFalse(selection.string?.isEmpty ?? true, "selection should yield text")
        let markup = AnnotationFactory.markup(for: selection, tool: .highlight,
                                              color: AnnotationPalette.swatches[0].nsColor)
        XCTAssertFalse(markup.isEmpty, "highlight should produce at least one markup annotation")
        for (p, annotation) in markup {
            XCTAssertEqual(annotation.type, "Highlight")
            XCTAssertNotNil(annotation.quadrilateralPoints)
            p.addAnnotation(annotation)
        }

        // 2) Add a sticky note.
        let note = AnnotationFactory.note(at: CGPoint(x: 100, y: 120), contents: "Reviewed by the annotations worker")
        page.addAnnotation(note)
        XCTAssertEqual(note.userName, NSFullUserName())

        // 3) Draw ink (smoothed).
        let raw = [CGPoint(x: 200, y: 200), CGPoint(x: 230, y: 250), CGPoint(x: 260, y: 200), CGPoint(x: 290, y: 250)]
        let smoothed = InkSmoothing.smooth(raw)
        let ink = try XCTUnwrap(AnnotationFactory.ink(paths: [smoothed], style: .init()))
        page.addAnnotation(ink)
        XCTAssertEqual(ink.type, "Ink")

        // 4) Drop a stamp (built-in "Approved").
        let stampDef = try XCTUnwrap(StampLibrary.builtIn(id: "Approved"))
        let stampImage = StampLibrary.image(for: stampDef)
        let stampSize = StampLibrary.suggestedSize(for: stampDef)
        let stamp = AnnotationFactory.stamp(image: stampImage,
                                            at: CGRect(x: 300, y: 400, width: stampSize.width, height: stampSize.height),
                                            name: stampDef.id)
        page.addAnnotation(stamp)

        let createdCount = listable(doc).count
        XCTAssertEqual(createdCount, markup.count + 3, "highlight(s) + note + ink + stamp")

        // 5) Export XFDF.
        let xfdf = XFDFService.export(doc)
        XCTAssertFalse(xfdf.isEmpty)
        // Sanity: the XFDF is well-formed XML and mentions our kinds.
        let xfdfString = try XCTUnwrap(String(data: xfdf, encoding: .utf8))
        XCTAssertTrue(xfdfString.contains("<highlight"))
        XCTAssertTrue(xfdfString.contains("<text"))
        XCTAssertTrue(xfdfString.contains("<ink"))
        XCTAssertTrue(xfdfString.contains("<stamp"))

        // 6) Re-import into a *fresh copy* of the same document.
        let copy = try sampleDocument()
        XCTAssertEqual(listable(copy).count, 0, "fresh copy has no annotations")
        let added = try XFDFService.import(xfdf, into: copy)
        XCTAssertEqual(added, createdCount, "every annotation imports into the copy")

        // 7) Verify: counts and per-annotation page+bounds preserved.
        var originals: [String: (Int, CGRect, String)] = [:]
        for i in 0..<doc.pageCount {
            for a in doc.page(at: i)!.annotations where a.isReamListable {
                originals[a.reamID] = (i, a.bounds, a.type ?? "")
            }
        }
        var verified = 0
        for i in 0..<copy.pageCount {
            for a in copy.page(at: i)!.annotations where a.isReamListable {
                let id = try XCTUnwrap(a.storedReamID)
                let original = try XCTUnwrap(originals[id])
                XCTAssertEqual(i, original.0, "annotation \(id) page")
                XCTAssertEqual(a.type, original.2, "annotation \(id) type")
                XCTAssertEqual(a.bounds.minX, original.1.minX, accuracy: 1.0)
                XCTAssertEqual(a.bounds.minY, original.1.minY, accuracy: 1.0)
                verified += 1
            }
        }
        XCTAssertEqual(verified, createdCount, "all annotations verified after re-import")

        // 8) Prove it survives a real PDF save/load too.
        let bytes = try XCTUnwrap(copy.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: bytes))
        reopened.delegate = AnnotationDocumentDelegate.shared
        XCTAssertEqual(listable(reopened).count, createdCount, "annotations persist through PDF save/load")
    }

    func testFlattenGoldenTail() throws {
        // Flatten after annotating: annotations become page content.
        let doc = try sampleDocument()
        let page = doc.page(at: 0)!
        let note = AnnotationFactory.note(at: CGPoint(x: 80, y: 80), contents: "flatten me")
        page.addAnnotation(note)
        XCTAssertEqual(listable(doc).count, 1)
        let flat = try XCTUnwrap(FlattenService.flatten(doc))
        XCTAssertEqual(flat.pageCount, doc.pageCount)
        XCTAssertEqual(listable(flat).count, 0, "flatten bakes annotations away")
    }
}
