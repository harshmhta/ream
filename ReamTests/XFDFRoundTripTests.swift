import XCTest
import PDFKit
import AppKit
@testable import Ream

/// The gating test for the annotations worker: export annotations to XFDF, then
/// import them into a *fresh copy* of the same document and assert count and
/// locations are preserved. Covers the interoperable annotation kinds Ream
/// creates.
final class XFDFRoundTripTests: XCTestCase {

    /// Build a small multi-page document in memory so the test is hermetic.
    private func makeDocument(pages: Int = 2) -> PDFDocument {
        let doc = PDFDocument()
        for i in 0..<pages {
            // PDFPage() defaults to a US-Letter media box (612×792).
            let page = PDFPage()
            doc.insert(page, at: i)
        }
        doc.delegate = AnnotationDocumentDelegate.shared
        return doc
    }

    /// A representative spread of annotation types with known geometry.
    private func populate(_ doc: PDFDocument) {
        let page0 = doc.page(at: 0)!
        let page1 = doc.page(at: 1)!

        // Highlight (markup with quad points) on page 0.
        let hl = PDFAnnotation(bounds: CGRect(x: 72, y: 700, width: 200, height: 16), forType: .highlight, withProperties: nil)
        hl.color = AnnotationPalette.swatches[0].nsColor
        hl.quadrilateralPoints = AnnotationFactory.quadPointValues(
            [CGRect(x: 72, y: 700, width: 200, height: 16)], relativeTo: CGPoint(x: 72, y: 700))
        AnnotationFactory.stampMetadata(on: hl)
        page0.addAnnotation(hl)

        // Sticky note on page 0.
        let note = AnnotationFactory.note(at: CGPoint(x: 120, y: 500), contents: "Check this figure")
        page0.addAnnotation(note)

        // Ink on page 1.
        if let ink = AnnotationFactory.ink(paths: [[
            CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 160), CGPoint(x: 180, y: 100)
        ]], style: .init()) {
            page1.addAnnotation(ink)
        }

        // Rectangle on page 1.
        let rect = AnnotationFactory.boxShape(.rectangle,
                                              rect: CGRect(x: 200, y: 300, width: 120, height: 80),
                                              style: .init())
        page1.addAnnotation(rect)

        // Arrow on page 1.
        let arrow = AnnotationFactory.lineShape(.arrow,
                                                from: CGPoint(x: 300, y: 500),
                                                to: CGPoint(x: 420, y: 560), style: .init())
        page1.addAnnotation(arrow)
    }

    private func listableCount(_ doc: PDFDocument) -> Int {
        var count = 0
        for i in 0..<doc.pageCount {
            count += doc.page(at: i)?.annotations.filter { $0.isReamListable }.count ?? 0
        }
        return count
    }

    func testExportImportPreservesCountAndLocations() throws {
        let source = makeDocument()
        populate(source)
        let originalCount = listableCount(source)
        XCTAssertEqual(originalCount, 5, "fixture should have 5 listable annotations")

        // Record each annotation's page + bounds keyed by Ream id.
        var originalByID: [String: (page: Int, bounds: CGRect, type: String)] = [:]
        for pageIndex in 0..<source.pageCount {
            for annotation in source.page(at: pageIndex)!.annotations where annotation.isReamListable {
                originalByID[annotation.reamID] = (pageIndex, annotation.bounds, annotation.type ?? "")
            }
        }

        // Export to XFDF.
        let xfdf = XFDFService.export(source)
        XCTAssertFalse(xfdf.isEmpty)

        // Import into a *fresh copy* (same geometry, zero annotations).
        let target = makeDocument()
        XCTAssertEqual(listableCount(target), 0, "fresh copy starts empty")
        let added = try XFDFService.import(xfdf, into: target)
        XCTAssertEqual(added, originalCount, "every annotation should import")
        XCTAssertEqual(listableCount(target), originalCount, "counts must match after round-trip")

        // Assert locations preserved (per Ream id, tolerant to sub-point noise).
        var matched = 0
        for pageIndex in 0..<target.pageCount {
            for annotation in target.page(at: pageIndex)!.annotations where annotation.isReamListable {
                guard let id = annotation.storedReamID, let original = originalByID[id] else {
                    XCTFail("imported annotation missing/unknown Ream id")
                    continue
                }
                XCTAssertEqual(pageIndex, original.page, "annotation \(id) landed on the wrong page")
                XCTAssertEqual(annotation.type, original.type, "annotation \(id) changed type")
                XCTAssertEqual(annotation.bounds.minX, original.bounds.minX, accuracy: 1.0,
                               "annotation \(id) x moved")
                XCTAssertEqual(annotation.bounds.minY, original.bounds.minY, accuracy: 1.0,
                               "annotation \(id) y moved")
                XCTAssertEqual(annotation.bounds.width, original.bounds.width, accuracy: 1.0)
                XCTAssertEqual(annotation.bounds.height, original.bounds.height, accuracy: 1.0)
                matched += 1
            }
        }
        XCTAssertEqual(matched, originalCount, "all imported annotations matched to originals")
    }

    func testRoundTripSurvivesPDFDataReload() throws {
        // Beyond XML round-trip: export → import → save the PDF bytes → reopen,
        // proving imported annotations persist through a real save/load.
        let source = makeDocument()
        populate(source)
        let xfdf = XFDFService.export(source)

        let target = makeDocument()
        try XFDFService.import(xfdf, into: target)
        let data = try XCTUnwrap(target.dataRepresentation())

        let reopened = try XCTUnwrap(PDFDocument(data: data))
        reopened.delegate = AnnotationDocumentDelegate.shared
        XCTAssertEqual(listableCount(reopened), 5, "annotations must survive a PDF save/load")
    }

    func testThreadingAndResolveStatePreserved() throws {
        let source = makeDocument(pages: 1)
        let page = source.page(at: 0)!
        let parent = AnnotationFactory.note(at: CGPoint(x: 100, y: 400), contents: "Parent comment")
        parent.reamResolved = true
        page.addAnnotation(parent)
        let reply = AnnotationFactory.reply(to: parent, contents: "A reply")
        page.addAnnotation(reply)

        let parentID = parent.reamID

        let xfdf = XFDFService.export(source)
        let target = makeDocument(pages: 1)
        try XFDFService.import(xfdf, into: target)

        let imported = target.page(at: 0)!.annotations.filter { $0.isReamListable }
        let importedReply = imported.first { $0.reamInReplyTo != nil }
        let importedParent = imported.first { $0.storedReamID == parentID }
        XCTAssertNotNil(importedReply, "reply linkage must survive")
        XCTAssertEqual(importedReply?.reamInReplyTo, parentID, "reply should point at parent id")
        XCTAssertEqual(importedParent?.reamResolved, true, "resolve state must survive")
    }

    func testLineEndpointsSurviveRoundTrip() throws {
        // Locks in the annotation-space ↔ absolute-page-space conversion for
        // line/arrow endpoints through XFDF.
        let source = makeDocument(pages: 1)
        let page = source.page(at: 0)!
        let a = CGPoint(x: 120, y: 300), b = CGPoint(x: 260, y: 420)
        let arrow = AnnotationFactory.lineShape(.arrow, from: a, to: b, style: .init())
        page.addAnnotation(arrow)
        // Absolute endpoints = bounds.origin + annotation-space endpoint.
        let originalStartAbs = CGPoint(x: arrow.bounds.minX + arrow.startPoint.x,
                                       y: arrow.bounds.minY + arrow.startPoint.y)
        let originalEndAbs = CGPoint(x: arrow.bounds.minX + arrow.endPoint.x,
                                     y: arrow.bounds.minY + arrow.endPoint.y)

        let xfdf = XFDFService.export(source)
        let target = makeDocument(pages: 1)
        try XFDFService.import(xfdf, into: target)

        let imported = try XCTUnwrap(target.page(at: 0)!.annotations.first { $0.type == "Line" })
        let importedStartAbs = CGPoint(x: imported.bounds.minX + imported.startPoint.x,
                                       y: imported.bounds.minY + imported.startPoint.y)
        let importedEndAbs = CGPoint(x: imported.bounds.minX + imported.endPoint.x,
                                     y: imported.bounds.minY + imported.endPoint.y)
        XCTAssertEqual(importedStartAbs.x, originalStartAbs.x, accuracy: 0.5)
        XCTAssertEqual(importedStartAbs.y, originalStartAbs.y, accuracy: 0.5)
        XCTAssertEqual(importedEndAbs.x, originalEndAbs.x, accuracy: 0.5)
        XCTAssertEqual(importedEndAbs.y, originalEndAbs.y, accuracy: 0.5)
        XCTAssertEqual(imported.endLineStyle, .closedArrow, "arrowhead style preserved")
    }

    func testInkGeometrySurvivesRoundTrip() throws {
        let source = makeDocument(pages: 1)
        let page = source.page(at: 0)!
        let stroke = [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 180), CGPoint(x: 200, y: 120)]
        let ink = try XCTUnwrap(AnnotationFactory.ink(paths: [stroke], style: .init()))
        page.addAnnotation(ink)

        let xfdf = XFDFService.export(source)
        let target = makeDocument(pages: 1)
        try XFDFService.import(xfdf, into: target)

        let imported = try XCTUnwrap(target.page(at: 0)!.annotations.first { $0.type == "Ink" })
        // Bounds should land within a point of the original (same page geometry).
        XCTAssertEqual(imported.bounds.minX, ink.bounds.minX, accuracy: 1.0)
        XCTAssertEqual(imported.bounds.minY, ink.bounds.minY, accuracy: 1.0)
        XCTAssertEqual(imported.paths?.count, 1, "one stroke preserved")
    }
}
