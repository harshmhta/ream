import Foundation
import PDFKit
import ReamCore

/// Reads and writes a PDF's document-information (Info dictionary) metadata,
/// bridging PDFKit's stringly-typed `documentAttributes` to the portable
/// ``DocumentMetadata`` value type from `ReamCore`.
///
/// All operations are pure with respect to page content — they only touch the
/// Info dictionary — so they honor the "fidelity is sacred" contract for
/// everything the user did not explicitly change.
enum PDFMetadataService {

    /// Read the current Info-dictionary metadata from a document.
    static func read(from document: PDFDocument) -> DocumentMetadata {
        let attrs = document.documentAttributes ?? [:]

        func string(_ key: PDFDocumentAttribute) -> String? {
            attrs[key] as? String
        }
        func date(_ key: PDFDocumentAttribute) -> Date? {
            attrs[key] as? Date
        }

        let keywords: [String]
        if let array = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            keywords = array
        } else if let joined = attrs[PDFDocumentAttribute.keywordsAttribute] as? String {
            // Some producers store keywords as a single comma/semicolon string.
            keywords = joined
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } else {
            keywords = []
        }

        return DocumentMetadata(
            title: string(.titleAttribute),
            author: string(.authorAttribute),
            subject: string(.subjectAttribute),
            keywords: keywords,
            creator: string(.creatorAttribute),
            producer: string(.producerAttribute),
            creationDate: date(.creationDateAttribute),
            modificationDate: date(.modificationDateAttribute)
        )
    }

    /// Apply edited metadata back onto a document's `documentAttributes`.
    ///
    /// Empty strings clear the corresponding key rather than writing an empty
    /// value, so "delete the title" actually removes `/Title` from the Info dict.
    static func apply(_ metadata: DocumentMetadata, to document: PDFDocument) {
        var attrs = document.documentAttributes ?? [:]

        func set(_ key: PDFDocumentAttribute, _ value: String?) {
            if let value, !value.isEmpty {
                attrs[key] = value
            } else {
                attrs.removeValue(forKey: key)
            }
        }

        set(.titleAttribute, metadata.title)
        set(.authorAttribute, metadata.author)
        set(.subjectAttribute, metadata.subject)
        set(.creatorAttribute, metadata.creator)
        set(.producerAttribute, metadata.producer)

        let cleanedKeywords = metadata.keywords
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if cleanedKeywords.isEmpty {
            attrs.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute)
        } else {
            attrs[PDFDocumentAttribute.keywordsAttribute] = cleanedKeywords
        }

        if let creationDate = metadata.creationDate {
            attrs[PDFDocumentAttribute.creationDateAttribute] = creationDate
        } else {
            attrs.removeValue(forKey: PDFDocumentAttribute.creationDateAttribute)
        }
        if let modificationDate = metadata.modificationDate {
            attrs[PDFDocumentAttribute.modificationDateAttribute] = modificationDate
        } else {
            attrs.removeValue(forKey: PDFDocumentAttribute.modificationDateAttribute)
        }

        document.documentAttributes = attrs
    }

    /// Wipe all Info-dictionary metadata (the "strip all metadata" scrub).
    ///
    /// Setting `documentAttributes` to empty clears Title/Author/Subject/
    /// Keywords/Creator. Producer and Creation/Modification dates are re-stamped
    /// by the PDF writer on the next save regardless — those are generic and
    /// non-identifying — but no user-supplied value survives. The accompanying
    /// full-rewrite save (see ``PDFSecurityService/strippedData(from:)``) also
    /// drops the catalog XMP stream, embedded thumbnails, and prior incremental
    /// versions.
    static func clearAll(on document: PDFDocument) {
        document.documentAttributes = [:]
    }
}
