import Foundation

/// A portable, engine-agnostic snapshot of a PDF's document-information metadata.
///
/// This mirrors the standard PDF *Info dictionary* fields (Title, Author, …) as
/// plain Swift values so the core stays UI- and PDFKit-free. The app layer maps
/// these to/from `PDFDocument.documentAttributes`; the future `pdfx` CLI and the
/// v1.0 engine can reuse the same value type headlessly.
public struct DocumentMetadata: Equatable, Sendable {
    /// Document title (Info `/Title`).
    public var title: String?
    /// Document author (Info `/Author`).
    public var author: String?
    /// Document subject / description (Info `/Subject`).
    public var subject: String?
    /// Keywords (Info `/Keywords`). Stored split; joined with ", " for display.
    public var keywords: [String]
    /// Creating application (Info `/Creator`) — surfaced in the UI as "Application".
    public var creator: String?
    /// Producer that generated the PDF bytes (Info `/Producer`) — "PDF Producer".
    public var producer: String?
    /// Creation timestamp (Info `/CreationDate`).
    public var creationDate: Date?
    /// Last-modification timestamp (Info `/ModDate`).
    public var modificationDate: Date?

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        keywords: [String] = [],
        creator: String? = nil,
        producer: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.producer = producer
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    /// An all-empty metadata record — the target state after a privacy strip.
    public static let empty = DocumentMetadata()

    /// The user-identifying fields a "strip all metadata" action removes.
    ///
    /// Producer / dates are intentionally excluded here because most PDF writers
    /// (including Apple's Quartz) re-stamp a generic producer and timestamps on
    /// every rewrite; those are non-identifying. Title/Author/Subject/Keywords/
    /// Creator are the fields that leak who made the document.
    public var identifyingFields: [(label: String, value: String)] {
        var fields: [(String, String)] = []
        if let title, !title.isEmpty { fields.append(("Title", title)) }
        if let author, !author.isEmpty { fields.append(("Author", author)) }
        if let subject, !subject.isEmpty { fields.append(("Subject", subject)) }
        if !keywords.isEmpty { fields.append(("Keywords", keywords.joined(separator: ", "))) }
        if let creator, !creator.isEmpty { fields.append(("Application", creator)) }
        return fields
    }

    /// True when no identifying field carries a value (post-strip state).
    public var hasNoIdentifyingData: Bool {
        identifyingFields.isEmpty
    }
}
