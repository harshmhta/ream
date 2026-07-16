import Foundation

/// A lightweight, engine-agnostic description of a PDF file.
///
/// This is a placeholder value type marking the seam where the real PDF object
/// model will live (v1.0). The app currently uses PDFKit for rendering; when
/// the content-stream editing engine (PDFium/MuPDF/pure-Swift, TBD) lands, it
/// will populate richer models here without the app layer needing to know which
/// engine produced them.
public struct PDFDescriptor: Equatable, Sendable {
    /// The file location on disk.
    public let url: URL

    /// Number of pages, if known. `nil` until a real parser fills it in.
    public let pageCount: Int?

    public init(url: URL, pageCount: Int? = nil) {
        self.url = url
        self.pageCount = pageCount
    }
}
