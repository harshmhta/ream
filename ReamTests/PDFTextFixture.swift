import Foundation
import PDFKit
import AppKit

/// Builds small PDFs with a known, extractable text layer for tests.
///
/// The bundled `sample.pdf` uses compressed content streams whose exact text is
/// opaque; these helpers instead render supplied strings into a real PDF text
/// layer so search / selection tests can assert against known content.
enum PDFTextFixture {

    /// Render one page per string, each drawn as body text, and return a loaded
    /// `PDFDocument`.
    static func makeDocument(pages: [String]) -> PDFDocument? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = pageRect
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        for page in pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.black
            ]
            let text = NSAttributedString(string: page, attributes: attrs)
            text.draw(in: CGRect(x: 48, y: 96, width: 516, height: 640))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()

        return PDFDocument(data: data as Data)
    }
}
