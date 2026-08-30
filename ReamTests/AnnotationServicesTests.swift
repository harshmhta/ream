import XCTest
import PDFKit
import AppKit
@testable import Ream

/// Unit tests for the headless annotation services (flatten, ink smoothing,
/// stamps, geometry) that don't need any UI.
final class AnnotationServicesTests: XCTestCase {

    private func makeDocument(pages: Int = 1) -> PDFDocument {
        let doc = PDFDocument()
        for i in 0..<pages { doc.insert(PDFPage(), at: i) }
        doc.delegate = AnnotationDocumentDelegate.shared
        return doc
    }

    // MARK: Document replacement

    /// Strip All Metadata / Remove Password / Flatten swap `pdfDocument` for a
    /// rebuilt one. The controller's selection and undo stacks point at
    /// annotations and pages of the old document, so undoing afterwards would
    /// re-add an annotation to a page that is no longer in the document.
    @MainActor
    func testDocumentReplacementClearsAnnotationState() throws {
        let refDoc = PDFReferenceDocument()
        refDoc.pdfDocument = makeDocument(pages: 1)
        let controller = AnnotationController(document: refDoc)

        let page = try XCTUnwrap(refDoc.pdfDocument.page(at: 0))
        let note = AnnotationFactory.boxShape(.rectangle,
                                              rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                                              style: .init())
        controller.add(note, to: page)
        controller.selectedAnnotation = note
        XCTAssertTrue(controller.canUndo)

        refDoc.pdfDocument = makeDocument(pages: 1)

        XCTAssertNil(controller.selectedAnnotation, "selection must not survive the swap")
        XCTAssertNil(controller.editingAnnotation)
        XCTAssertFalse(controller.canUndo, "undo must not target the replaced document's pages")
        XCTAssertFalse(controller.canRedo)
    }

    // MARK: Flatten

    func testFlattenAllRemovesAnnotationsButKeepsPages() throws {
        let doc = makeDocument(pages: 2)
        let hl = PDFAnnotation(bounds: CGRect(x: 72, y: 700, width: 200, height: 16), forType: .highlight, withProperties: nil)
        hl.color = .yellow
        hl.quadrilateralPoints = AnnotationFactory.quadPointValues(
            [CGRect(x: 72, y: 700, width: 200, height: 16)], relativeTo: CGPoint(x: 72, y: 700))
        doc.page(at: 0)!.addAnnotation(hl)

        let flat = try XCTUnwrap(FlattenService.flatten(doc))
        XCTAssertEqual(flat.pageCount, 2, "flatten must preserve page count")
        XCTAssertEqual(flat.page(at: 0)!.annotations.count, 0, "annotations must be baked away")
        // Media box preserved.
        XCTAssertEqual(flat.page(at: 0)!.bounds(for: .mediaBox).width,
                       doc.page(at: 0)!.bounds(for: .mediaBox).width, accuracy: 1)
    }

    func testFlattenSelectedKeepsOthersLive() throws {
        let doc = makeDocument(pages: 1)
        let page = doc.page(at: 0)!
        let a = AnnotationFactory.boxShape(.rectangle, rect: CGRect(x: 50, y: 50, width: 60, height: 60), style: .init())
        let b = AnnotationFactory.boxShape(.rectangle, rect: CGRect(x: 200, y: 200, width: 60, height: 60), style: .init())
        page.addAnnotation(a)
        page.addAnnotation(b)

        let flat = try XCTUnwrap(FlattenService.flatten(doc, only: [a]))
        // `b` should remain a live annotation; `a` baked into content.
        XCTAssertEqual(flat.page(at: 0)!.annotations.count, 1, "only the unselected annotation stays live")
    }

    // MARK: Ink smoothing

    func testCatmullRomPassesThroughEndpoints() {
        let raw = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 25)]
        let smoothed = InkSmoothing.smooth(raw, algorithm: .catmullRom)
        XCTAssertGreaterThan(smoothed.count, raw.count, "smoothing should densify the stroke")
        XCTAssertEqual(smoothed.first!, raw.first!, "start point preserved")
        XCTAssertEqual(smoothed.last!.x, raw.last!.x, accuracy: 0.001, "end point preserved")
        XCTAssertEqual(smoothed.last!.y, raw.last!.y, accuracy: 0.001)
    }

    func testChaikinKeepsEndpointsAndAddsPoints() {
        let raw = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 0)]
        let smoothed = InkSmoothing.smooth(raw, algorithm: .chaikin, iterations: 2)
        XCTAssertEqual(smoothed.first!, raw.first!)
        XCTAssertEqual(smoothed.last!, raw.last!)
        XCTAssertGreaterThan(smoothed.count, raw.count)
    }

    func testShortStrokeUnchanged() {
        let raw = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]
        XCTAssertEqual(InkSmoothing.smooth(raw).count, 2)
    }

    // MARK: Stamps

    func testDynamicStampTokensResolve() {
        let resolved = StampLibrary.resolve("RECEIVED {date} by {user}")
        XCTAssertFalse(resolved.contains("{date}"), "date token must be filled")
        XCTAssertFalse(resolved.contains("{user}"), "user token must be filled")
        XCTAssertTrue(resolved.contains(NSFullUserName()))
    }

    func testBuiltInStampImageRenders() {
        let stamp = try! XCTUnwrap(StampLibrary.builtIn(id: "Approved"))
        let image = StampLibrary.image(for: stamp)
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // MARK: Geometry

    func testPackUnpackRoundTrips() {
        let points = [CGPoint(x: 1.5, y: 2), CGPoint(x: 3, y: 4.25), CGPoint(x: -5, y: 6)]
        let packed = ReamGeometry.packPoints(points)
        let unpacked = ReamGeometry.unpackPoints(packed)
        XCTAssertEqual(unpacked.count, points.count)
        for (a, b) in zip(points, unpacked) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
        }
    }

    func testDistanceToSegment() {
        let d = ReamGeometry.distance(from: CGPoint(x: 5, y: 5), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        XCTAssertEqual(d, 5, accuracy: 0.001)
    }

    // MARK: Markup factory

    func testMarkupSquigglyIsCustomSubclass() {
        // Build a selection over a text page to exercise markup(for:).
        let doc = makeDocument(pages: 1)
        // No text on synthetic page, so markup(for:) returns empty — assert it
        // degrades gracefully rather than crashing.
        let selection = PDFSelection(document: doc)
        let result = AnnotationFactory.markup(for: selection, tool: .squiggly, color: .yellow)
        XCTAssertTrue(result.isEmpty, "empty selection yields no markup")
    }
}
