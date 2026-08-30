import XCTest
import PDFKit
import AppKit
@testable import Ream

/// Pixel-level verification of content-aware dark inversion, driving the real
/// ``InvertingPDFPage`` draw path.
///
/// The hard promise of dark-content mode is "invert the paper, *keep* colour
/// photos". These tests render a page with a white background, black text, and
/// saturated red/green rectangles, then sample pixels to prove:
///   • the paper background goes dark, and
///   • the coloured rectangles stay recognisably red / green (not inverted to
///     cyan / magenta).
/// Rendered PNGs are also written to `REAM_RENDER_DIR` when that env var is set,
/// for visual inspection / PR artifacts.
final class DarkContentRenderTests: XCTestCase {

    /// Render `page` at 2× into an RGBA bitmap we can sample.
    private func renderBitmap(_ page: PDFPage, box: PDFDisplayBox = .mediaBox, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let bounds = page.bounds(for: box)
        let pw = Int(bounds.width * scale), ph = Int(bounds.height * scale)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: box, to: cg)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func dumpIfRequested(_ rep: NSBitmapImageRep, name: String) {
        let dir = ProcessInfo.processInfo.environment["REAM_RENDER_DIR"] ?? "/tmp/ream_render"
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let dirURL = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try? png.write(to: dirURL.appendingPathComponent(name))
    }

    /// A page whose top half is white with black text and whose bottom half has
    /// a red and a green rectangle (matching the /tmp golden-path fixture).
    private func makeColorfulDocument() throws -> InvertingPDFDocument {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 300)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var media = rect
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        ctx.beginPDFPage(nil)
        // White paper.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        // Black text-ish bar near the top.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 30, y: 240, width: 240, height: 20))
        // Saturated colour blocks near the bottom.
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fill(CGRect(x: 30, y: 40, width: 100, height: 100))
        ctx.setFillColor(NSColor.green.cgColor)
        ctx.fill(CGRect(x: 170, y: 40, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
        let doc = try XCTUnwrap(InvertingPDFDocument(data: data as Data))
        // Install the shared delegate that vends InvertingPDFPage (production
        // does this in PDFReferenceDocument); without it, pages draw stock and
        // inversion never runs.
        doc.delegate = AnnotationDocumentDelegate.shared
        return doc
    }

    /// Sample average RGB in a small region (page-space rect), for a 2× render.
    private func avgColor(_ rep: NSBitmapImageRep, pageRect: CGRect, pageHeight: CGFloat, scale: CGFloat = 2) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        // Page space is y-up; bitmap rows are y-down.
        var rs: CGFloat = 0, gs: CGFloat = 0, bs: CGFloat = 0, n: CGFloat = 0
        let x0 = Int(pageRect.minX * scale), x1 = Int(pageRect.maxX * scale)
        let y0 = Int((pageHeight - pageRect.maxY) * scale), y1 = Int((pageHeight - pageRect.minY) * scale)
        for x in stride(from: x0, to: x1, by: 3) {
            for y in stride(from: y0, to: y1, by: 3) {
                guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
                      let c = rep.colorAt(x: x, y: y) else { continue }
                rs += c.redComponent; gs += c.greenComponent; bs += c.blueComponent; n += 1
            }
        }
        guard n > 0 else { return (0, 0, 0) }
        return (rs/n, gs/n, bs/n)
    }

    func testInversionDarkensPaperAndPreservesColor() throws {
        let doc = try makeColorfulDocument()
        let page = try XCTUnwrap(doc.page(at: 0))
        let h = page.bounds(for: .mediaBox).height

        // Regions to sample.
        let paper = CGRect(x: 30, y: 150, width: 240, height: 60)   // white area above colours
        let redBox = CGRect(x: 40, y: 55, width: 70, height: 70)
        let greenBox = CGRect(x: 180, y: 55, width: 70, height: 70)

        // --- Light mode ---
        doc.invertContent = false
        let light = try renderBitmap(page)
        dumpIfRequested(light, name: "page_light.png")
        let lightPaper = avgColor(light, pageRect: paper, pageHeight: h)
        let lightRed = avgColor(light, pageRect: redBox, pageHeight: h)
        XCTAssertGreaterThan(lightPaper.r, 0.8, "paper should start light")
        XCTAssertGreaterThan(lightRed.r, 0.5, "red box should be red in light mode")
        XCTAssertLessThan(lightRed.g, 0.4)

        // --- Dark mode ---
        doc.invertContent = true
        let dark = try renderBitmap(page)
        dumpIfRequested(dark, name: "page_dark.png")
        let darkPaper = avgColor(dark, pageRect: paper, pageHeight: h)
        let darkRed = avgColor(dark, pageRect: redBox, pageHeight: h)
        let darkGreen = avgColor(dark, pageRect: greenBox, pageHeight: h)

        // Paper must darken substantially.
        let lightLuma = 0.299*lightPaper.r + 0.587*lightPaper.g + 0.114*lightPaper.b
        let darkLuma = 0.299*darkPaper.r + 0.587*darkPaper.g + 0.114*darkPaper.b
        XCTAssertLessThan(darkLuma, lightLuma - 0.3, "paper should become clearly darker")
        XCTAssertLessThan(darkLuma, 0.5)

        // Colour boxes must stay recognisably red / green (not become their
        // colour-inverted complements). Red stays red-dominant; green stays
        // green-dominant.
        XCTAssertGreaterThan(darkRed.r, darkRed.g, "red box should stay red-dominant in dark mode")
        XCTAssertGreaterThan(darkRed.r, darkRed.b)
        XCTAssertGreaterThan(darkGreen.g, darkGreen.r, "green box should stay green-dominant in dark mode")
        XCTAssertGreaterThan(darkGreen.g, darkGreen.b)
    }
}
