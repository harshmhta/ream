import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pure, UI-free page & document operations on `PDFKit.PDFDocument`.
///
/// Everything here is a static function that takes documents/pages in and
/// returns new documents/pages out — no window, no `PDFView`, no
/// `NSUndoManager`. That keeps the operations trivially unit-testable (see
/// `PageOperationsTests`) and lets the higher layers (``PageOpsController``,
/// ``PDFReferenceDocument``) own presentation, undo, and background scheduling.
///
/// These live in the app target rather than `ReamCore` on purpose: they lean on
/// PDFKit, and `ReamCore` is contractually UI-free (no PDFKit-UI). The v1.0
/// fidelity-preserving engine will land in `ReamCore`; these v0.1 page ops build
/// on PDFKit's page model, which never rewrites untouched page content streams.
enum PageOperations {

    /// Errors surfaced by page operations.
    enum OperationError: LocalizedError, Equatable {
        case cancelled
        case invalidRange(String)
        case emptyResult
        case couldNotReadImage(URL)
        case couldNotCreatePage

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "The operation was cancelled."
            case .invalidRange(let spec):
                return "“\(spec)” is not a valid page range."
            case .emptyResult:
                return "The operation produced no pages."
            case .couldNotReadImage(let url):
                return "Could not read the image at \(url.lastPathComponent)."
            case .couldNotCreatePage:
                return "Could not create a new page."
            }
        }
    }

    // MARK: - Merge

    /// Merge several documents into one new document.
    ///
    /// - Parameters:
    ///   - documents: source documents, in the desired output order.
    ///   - interleave: when `true`, round-robin pages across documents
    ///     (`A1, B1, A2, B2, …`) — the fix for duplex scanners that produce one
    ///     file of odd pages and one of even pages. When `false`, documents are
    ///     concatenated end-to-end.
    ///   - isCancelled: polled between pages; throws ``OperationError/cancelled``.
    ///   - onProgress: reports 0…1 completion for a progress panel.
    /// - Returns: a fresh `PDFDocument` containing copies of every source page.
    static func merge(
        _ documents: [PDFDocument],
        interleave: Bool = false,
        isCancelled: () -> Bool = { false },
        onProgress: (Double) -> Void = { _ in }
    ) throws -> PDFDocument {
        let output = PDFDocument()
        let totalPages = documents.reduce(0) { $0 + $1.pageCount }
        guard totalPages > 0 else { return output }

        var inserted = 0
        func append(_ page: PDFPage) throws {
            if isCancelled() { throw OperationError.cancelled }
            guard let copy = page.copy() as? PDFPage else { throw OperationError.couldNotCreatePage }
            output.insert(copy, at: output.pageCount)
            inserted += 1
            onProgress(Double(inserted) / Double(totalPages))
        }

        if interleave {
            let maxCount = documents.map(\.pageCount).max() ?? 0
            for position in 0..<maxCount {
                for document in documents where position < document.pageCount {
                    if let page = document.page(at: position) { try append(page) }
                }
            }
        } else {
            for document in documents {
                for index in 0..<document.pageCount {
                    if let page = document.page(at: index) { try append(page) }
                }
            }
        }
        return output
    }

    // MARK: - Range parsing

    /// Parse an iLovePDF-style range spec into segments of **0-based** page
    /// indices — one inner array per comma-separated token.
    ///
    /// Grammar (1-based, inclusive) with `n` = `pageCount`:
    /// - `"5"`        → `[[4]]`
    /// - `"1-3"`      → `[[0,1,2]]`
    /// - `"10-"`      → `[[9, …, n-1]]` (open end)
    /// - `"-3"`       → `[[0,1,2]]` (open start)
    /// - `"1-3, 7"`   → `[[0,1,2], [6]]` (two segments → two output files)
    ///
    /// Throws ``OperationError/invalidRange(_:)`` on malformed or out-of-bounds
    /// input so the UI can show a precise message.
    static func parsePageRanges(_ spec: String, pageCount: Int) throws -> [[Int]] {
        let tokens = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let usable = tokens.filter { !$0.isEmpty }
        guard !usable.isEmpty else { throw OperationError.invalidRange(spec) }
        guard pageCount > 0 else { throw OperationError.invalidRange(spec) }

        var segments: [[Int]] = []
        for token in usable {
            let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

            func page(_ s: Substring) throws -> Int {
                guard let n = Int(s.trimmingCharacters(in: .whitespaces)), n >= 1, n <= pageCount else {
                    throw OperationError.invalidRange(token)
                }
                return n
            }

            if !token.contains("-") {
                // Single page.
                let one = try page(Substring(token))
                segments.append([one - 1])
                continue
            }

            // Range with an optional open start/end.
            let lowerRaw = parts.first ?? ""
            let upperRaw = parts.count > 1 ? parts[1] : ""
            let lower = lowerRaw.trimmingCharacters(in: .whitespaces).isEmpty ? 1 : try page(lowerRaw)
            let upper = upperRaw.trimmingCharacters(in: .whitespaces).isEmpty ? pageCount : try page(upperRaw)
            guard lower <= upper else { throw OperationError.invalidRange(token) }
            segments.append(Array((lower - 1)...(upper - 1)))
        }
        return segments
    }

    // MARK: - Split

    /// Split a document into one output document per range-spec segment.
    static func split(_ document: PDFDocument, ranges spec: String) throws -> [PDFDocument] {
        let segments = try parsePageRanges(spec, pageCount: document.pageCount)
        let outputs = segments.map { extract(document, pages: $0) }
        guard outputs.contains(where: { $0.pageCount > 0 }) else { throw OperationError.emptyResult }
        return outputs
    }

    /// Split into consecutive chunks of at most `n` pages each.
    static func split(_ document: PDFDocument, everyN n: Int) throws -> [PDFDocument] {
        guard n >= 1 else { throw OperationError.invalidRange("\(n)") }
        guard document.pageCount > 0 else { throw OperationError.emptyResult }
        var outputs: [PDFDocument] = []
        var start = 0
        while start < document.pageCount {
            let end = min(start + n, document.pageCount)
            outputs.append(extract(document, pages: Array(start..<end)))
            start = end
        }
        return outputs
    }

    /// Split at the page of each top-level (depth-1) outline entry. Returns an
    /// empty array when the document has no usable top-level bookmarks so the UI
    /// can explain why rather than emitting a single passthrough file.
    static func splitByBookmarks(_ document: PDFDocument) -> [PDFDocument] {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return [] }

        // Collect the first page index of every top-level bookmark, in order.
        var boundaries: [Int] = []
        for i in 0..<root.numberOfChildren {
            if let dest = root.child(at: i)?.destination, let page = dest.page {
                let index = document.index(for: page)
                if index != NSNotFound { boundaries.append(index) }
            }
        }
        boundaries = Array(Set(boundaries)).sorted()
        guard let first = boundaries.first else { return [] }

        // Ensure any pages before the first bookmark become their own segment.
        if first > 0 { boundaries.insert(0, at: 0) }

        var outputs: [PDFDocument] = []
        for (i, start) in boundaries.enumerated() {
            let end = (i + 1 < boundaries.count) ? boundaries[i + 1] : document.pageCount
            guard start < end else { continue }
            outputs.append(extract(document, pages: Array(start..<end)))
        }
        return outputs
    }

    // MARK: - Extract

    /// Copy the given **0-based** page indices (in the order supplied) into a new
    /// document. Out-of-bounds indices are skipped.
    static func extract(_ document: PDFDocument, pages indices: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in indices where index >= 0 && index < document.pageCount {
            if let page = document.page(at: index)?.copy() as? PDFPage {
                output.insert(page, at: output.pageCount)
            }
        }
        return output
    }

    // MARK: - Page construction

    /// Standard blank-page sizes (points, 72 dpi).
    enum BlankSize {
        static let usLetter = CGSize(width: 612, height: 792)
        static let a4 = CGSize(width: 595, height: 842)
    }

    /// Build a genuine (vector, not rasterized) blank page of the given size by
    /// producing a one-page empty PDF and reading its page back.
    static func makeBlankPage(size: CGSize) -> PDFPage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        context.beginPDFPage(nil)
        // Paint the page white so it reads as a real blank sheet rather than a
        // transparent one (important once it sits between content pages).
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    /// Build one page per image file, sized to each image. Skips files that fail
    /// to decode unless `strict` is set. Cancellable + progress-reporting for
    /// large batches.
    static func makePages(
        fromImageURLs urls: [URL],
        strict: Bool = false,
        isCancelled: () -> Bool = { false },
        onProgress: (Double) -> Void = { _ in }
    ) throws -> [PDFPage] {
        var pages: [PDFPage] = []
        for (i, url) in urls.enumerated() {
            if isCancelled() { throw OperationError.cancelled }
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                pages.append(page)
            } else if strict {
                throw OperationError.couldNotReadImage(url)
            }
            onProgress(urls.isEmpty ? 1 : Double(i + 1) / Double(urls.count))
        }
        return pages
    }
}
