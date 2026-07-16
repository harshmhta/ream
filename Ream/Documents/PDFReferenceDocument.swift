import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// The document model backing every open PDF.
///
/// We adopt `ReferenceFileDocument` (a reference type) rather than the value-type
/// `FileDocument` because `PDFKit.PDFDocument` is a reference type and we want a
/// single shared instance per window that views and view models can mutate in
/// place (Phase 2: annotations, page ops). For v0.1 the document is read-only
/// from the UI's perspective — we never mutate the bytes — but the seam is ready.
final class PDFReferenceDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    /// The PDFKit document being displayed. `nil` only if the file failed to parse.
    @Published var pdfDocument: PDFKit.PDFDocument

    /// PDF is the one and only readable/writable content type in v0.1.
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    /// Create an empty (zero-page) document. Used as a last-resort fallback.
    init() {
        self.pdfDocument = PDFKit.PDFDocument()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let doc = PDFKit.PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdfDocument = doc
    }

    /// Snapshot the current bytes so autosave/versions can persist them.
    ///
    /// v0.1 never edits content, so this returns the original document data
    /// unchanged — a byte-stable no-op round-trip, honoring the "fidelity is
    /// sacred" principle from the scope.
    func snapshot(contentType: UTType) throws -> Data {
        guard let data = pdfDocument.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
