import PDFKit
import AppKit

/// Bakes annotations into page content so they become part of the page's
/// pixels rather than editable overlays. Ream renders each page (which includes
/// its annotations) into a fresh PDF page via a `CGPDFContext`, then the
/// annotations are gone from the object model — reversible only by re-loading
/// the pre-flatten document (as the brief states).
enum FlattenService {

    /// Flatten either every page or just the pages carrying the given
    /// annotations. Returns a brand-new `PDFDocument`; the caller decides
    /// whether to swap it into the open document.
    ///
    /// - Parameters:
    ///   - document: the source document (not mutated).
    ///   - selectedAnnotations: when non-nil, only these annotations are baked;
    ///     other annotations on those pages are preserved as live annotations.
    static func flatten(_ document: PDFDocument,
                        only selectedAnnotations: [PDFAnnotation]? = nil) -> PDFDocument? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }

        let selectedIDs: Set<String>? = selectedAnnotations.map { set in
            Set(set.compactMap { $0.storedReamID })
        }

        // Copy document-level attributes so metadata survives the rebuild.
        let auxiliaryInfo = pdfAuxiliaryInfo(from: document.documentAttributes ?? [:])
        guard let context = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo) else { return nil }

        // Live annotations to re-attach after the rebuild, keyed by page index.
        // (The flattened document is brand new, so their copies must be added
        // back onto the corresponding flattened page.)
        var liveByPage: [Int: [PDFAnnotation]] = [:]

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var mediaBox = page.bounds(for: .mediaBox)

            // Which annotations to keep live (not bake) on this page?
            let liveAnnotations: [PDFAnnotation]
            if let selectedIDs {
                liveAnnotations = page.annotations.filter { annotation in
                    guard let id = annotation.storedReamID else { return true }
                    return !selectedIDs.contains(id)   // keep unselected ones live
                }
            } else {
                liveAnnotations = []
            }
            // Snapshot copies now, before drawing, so the originals can be
            // restored and re-attached to the new document.
            if !liveAnnotations.isEmpty {
                liveByPage[pageIndex] = liveAnnotations.compactMap { $0.copy() as? PDFAnnotation }
            }

            // Temporarily remove the live annotations so page.draw doesn't bake
            // them, then restore them afterward.
            for annotation in liveAnnotations { page.removeAnnotation(annotation) }

            // Constrain the new page to the source media box.
            let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &mediaBox,
                                                                    length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.endPDFPage()

            for annotation in liveAnnotations { page.addAnnotation(annotation) }
        }
        context.closePDF()

        guard let flattened = PDFDocument(data: data as Data) else { return nil }
        flattened.delegate = AnnotationDocumentDelegate.shared
        // Re-attach the preserved live annotations to the flattened pages.
        for (pageIndex, annotations) in liveByPage {
            guard let page = flattened.page(at: pageIndex) else { continue }
            for annotation in annotations { page.addAnnotation(annotation) }
        }
        return flattened
    }

    private static func pdfAuxiliaryInfo(from attributes: [AnyHashable: Any]) -> CFDictionary {
        var info: [CFString: Any] = [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String {
            info[kCGPDFContextTitle] = title
        }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String {
            info[kCGPDFContextAuthor] = author
        }
        return info as CFDictionary
    }
}
