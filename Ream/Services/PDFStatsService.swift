import Foundation
import PDFKit

/// Read-only document statistics shown in the Document Properties dialog:
/// page count, file size, PDF version, and the tagged / linearized / encrypted
/// flags. These never mutate the document.
struct PDFDocumentStats {
    let pageCount: Int
    let fileSizeBytes: Int?
    let pdfVersion: String
    let isTagged: Bool
    let isLinearized: Bool
    let isEncrypted: Bool

    /// Human-readable file size (e.g. "1.2 MB"), or "—" when unknown.
    var fileSizeDisplay: String {
        guard let bytes = fileSizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum PDFStatsService {

    /// Gather stats for a document. `fileURL` (when known) yields file size and
    /// enables byte-level detection of linearization/tagging that PDFKit does
    /// not expose directly. Falls back to the in-memory data representation.
    static func stats(for document: PDFDocument, fileURL: URL?) -> PDFDocumentStats {
        let version = "\(document.majorVersion).\(document.minorVersion)"

        let fileSize: Int?
        if let fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int {
            fileSize = size
        } else {
            fileSize = document.dataRepresentation()?.count
        }

        // PDFKit has no tagged/linearized API. Detect from the leading bytes of
        // the file (linearization dict lives near the head; the structure tree
        // root marks a tagged PDF). We only scan a bounded prefix to stay fast on
        // large files.
        var isTagged = false
        var isLinearized = false
        if let head = headBytes(fileURL: fileURL, document: document, limit: 4096) {
            isLinearized = contains(head, "/Linearized")
        }
        if let markers = markerBytes(fileURL: fileURL, document: document) {
            isTagged = contains(markers, "/MarkInfo") || contains(markers, "/StructTreeRoot")
        }

        return PDFDocumentStats(
            pageCount: document.pageCount,
            fileSizeBytes: fileSize,
            pdfVersion: version,
            isTagged: isTagged,
            isLinearized: isLinearized,
            isEncrypted: document.isEncrypted
        )
    }

    /// The first `limit` bytes of the file (or in-memory data).
    private static func headBytes(fileURL: URL?, document: PDFDocument, limit: Int) -> Data? {
        if let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) {
            defer { try? handle.close() }
            return try? handle.read(upToCount: limit)
        }
        return document.dataRepresentation()?.prefix(limit)
    }

    /// Bytes to scan for structural markers. Tagging markers live in the catalog,
    /// which may be anywhere, so we scan the whole file when it is reasonably
    /// small and otherwise sample the head + tail.
    private static func markerBytes(fileURL: URL?, document: PDFDocument) -> Data? {
        let full: Data?
        if let fileURL {
            full = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        } else {
            full = document.dataRepresentation()
        }
        guard let data = full else { return nil }
        // Scanning up to ~2 MB is cheap; for larger files sample head + tail where
        // the catalog / xref (and thus the structure references) usually sit.
        let cap = 2 * 1024 * 1024
        if data.count <= cap { return data }
        var sample = Data()
        sample.append(data.prefix(cap / 2))
        sample.append(data.suffix(cap / 2))
        return sample
    }

    private static func contains(_ data: Data, _ token: String) -> Bool {
        guard let needle = token.data(using: .isoLatin1) else { return false }
        return data.range(of: needle) != nil
    }
}
