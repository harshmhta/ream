import Foundation
import PDFKit
import ReamCore

/// Encryption, decryption, and privacy-scrub operations for a PDF, built on
/// PDFKit + CoreGraphics.
///
/// ## Encryption strength
/// Apple's native PDF writer (`PDFDocument.dataRepresentation(options:)`, which
/// sits on `CGPDFContext`) emits **AES-128** (`/V 4 /R 4 /CFM /AESV2`) — this is
/// the strongest algorithm reachable without bundling a third-party C/C++ engine
/// (qpdf/PDFium). True AES-256 (`/V 5 /R 6 /AESV3`, PDF 2.0) is tracked as a
/// follow-up for when the portable `ReamCore` PDF object model lands; adding it
/// now would mean a native dependency and a project-wide licensing decision that
/// is out of scope for v0.1. Verified empirically on macOS 26 / Xcode 26.
///
/// ## Why some operations rebuild pages
/// PDFKit's writer *retains* an existing catalog XMP `/Metadata` stream and an
/// existing `/Encrypt` dictionary across a plain `dataRepresentation()` — even
/// after clearing `documentAttributes` or unlocking. The only reliable way to
/// truly remove encryption or scrub XMP is to copy each page into a brand-new
/// `PDFDocument`, which starts with an empty catalog. Rebuilt pages render
/// pixel-identical to the originals (page content streams are copied verbatim).
enum PDFSecurityService {

    // MARK: - Errors

    enum SecurityError: LocalizedError {
        case noPasswordProvided
        case writeFailed
        case documentLocked

        var errorDescription: String? {
            switch self {
            case .noPasswordProvided:
                return "Enter at least one password (open or permissions) to encrypt the document."
            case .writeFailed:
                return "Could not write the document. It may be corrupt or unsupported."
            case .documentLocked:
                return "The document is still locked. Unlock it with its password first."
            }
        }
    }

    // MARK: - Permission mapping

    /// Map our portable ``DocumentPermissions`` to the raw `PDFAccessPermissions`
    /// bitmask that `PDFDocumentAccessPermissionsOption` expects (wrapped in an
    /// `NSNumber` at the call site). Granting a capability grants its documented
    /// supersets so the on-disk flags match user intent (e.g. "allow edit" also
    /// permits assembly).
    ///
    /// - Note: `PDFAccessPermissions` is imported as a plain enum, so an OR'd
    ///   combination is not a valid single case; we work with the raw bitmask
    ///   directly, which is exactly what the write option consumes.
    static func accessPermissionsRawValue(from permissions: DocumentPermissions) -> UInt {
        var raw: UInt = 0
        if permissions.contains(.print) {
            raw |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue
            raw |= PDFAccessPermissions.allowsHighQualityPrinting.rawValue
        }
        if permissions.contains(.copy) {
            raw |= PDFAccessPermissions.allowsContentCopying.rawValue
            raw |= PDFAccessPermissions.allowsContentAccessibility.rawValue
        }
        if permissions.contains(.edit) {
            raw |= PDFAccessPermissions.allowsDocumentChanges.rawValue
            raw |= PDFAccessPermissions.allowsDocumentAssembly.rawValue
        }
        if permissions.contains(.annotate) {
            raw |= PDFAccessPermissions.allowsCommenting.rawValue
            raw |= PDFAccessPermissions.allowsFormFieldEntry.rawValue
        }
        return raw
    }

    /// Read the current effective permissions of an (unlocked) document.
    static func permissions(of document: PDFDocument) -> DocumentPermissions {
        var result: DocumentPermissions = []
        if document.allowsPrinting { result.insert(.print) }
        if document.allowsCopying { result.insert(.copy) }
        if document.allowsDocumentChanges { result.insert(.edit) }
        if document.allowsCommenting { result.insert(.annotate) }
        return result
    }

    // MARK: - Encrypt

    /// Produce encrypted PDF bytes for `document` using the given settings.
    ///
    /// - Note: PDFKit only enforces permission flags when an **owner** password
    ///   is set; with only a user password the file opens freely once unlocked.
    ///   The UI nudges users toward setting an owner password when they restrict
    ///   permissions.
    static func encryptedData(
        from document: PDFDocument,
        settings: EncryptionSettings
    ) throws -> Data {
        let settings = settings.normalized
        guard settings.hasAnyPassword else { throw SecurityError.noPasswordProvided }

        var options: [PDFDocumentWriteOption: Any] = [:]
        if let user = settings.userPassword {
            options[.userPasswordOption] = user
        }
        if let owner = settings.ownerPassword {
            options[.ownerPasswordOption] = owner
        } else if let user = settings.userPassword {
            // CGPDFContext requires an owner password to encrypt; if the user only
            // set an open password, reuse it as the owner password so the write
            // succeeds. (Otherwise permissions would be unprotected anyway.)
            options[.ownerPasswordOption] = user
        }

        let accessRaw = accessPermissionsRawValue(from: settings.permissions)
        options[.accessPermissionsOption] = NSNumber(value: accessRaw)

        guard let data = document.dataRepresentation(options: options) else {
            throw SecurityError.writeFailed
        }
        return data
    }

    // MARK: - Decrypt / remove password

    /// Produce a decrypted (unencrypted) copy of an **unlocked** document.
    ///
    /// Requires the document to be unlocked already (the user supplied the open
    /// password). Rebuilds the page tree into a fresh document so no `/Encrypt`
    /// dictionary survives, then carries the Info-dictionary metadata forward.
    static func decryptedDocument(from document: PDFDocument) throws -> PDFDocument {
        guard !document.isLocked else { throw SecurityError.documentLocked }
        return rebuild(document, stripAnnotations: false, clearMetadata: false)
    }

    /// `decryptedDocument(from:)` serialized to bytes (for export / tests).
    static func decryptedData(from document: PDFDocument) throws -> Data {
        guard let data = try decryptedDocument(from: document).dataRepresentation() else {
            throw SecurityError.writeFailed
        }
        return data
    }

    // MARK: - Strip all metadata

    /// Produce a fully metadata-scrubbed copy of the document.
    ///
    /// Removes: the Info dictionary (Title/Author/Subject/Keywords/Creator), the
    /// catalog XMP `/Metadata` stream, embedded page thumbnails, all annotations
    /// ("comments"), and — because it is a full rewrite into a new document —
    /// any prior incremental-update versions. Producer and Creation/Modification
    /// dates are re-stamped by the writer with generic, non-identifying values.
    ///
    /// - Note: A full rewrite also drops the document outline/bookmarks and any
    ///   attachments; the confirmation UI lists these so the user is not
    ///   surprised.
    static func strippedDocument(from document: PDFDocument) throws -> PDFDocument {
        guard !document.isLocked else { throw SecurityError.documentLocked }
        return rebuild(document, stripAnnotations: true, clearMetadata: true)
    }

    /// `strippedDocument(from:)` serialized to bytes (for export / tests).
    static func strippedData(from document: PDFDocument) throws -> Data {
        guard let data = try strippedDocument(from: document).dataRepresentation() else {
            throw SecurityError.writeFailed
        }
        return data
    }

    // MARK: - Shared page rebuild

    /// Copy every page of `document` into a fresh `PDFDocument`.
    ///
    /// A new document has an empty catalog, so this is the only way to guarantee
    /// removal of an existing `/Encrypt` dictionary or XMP `/Metadata` stream
    /// (PDFKit otherwise carries both forward). Page *content* is copied verbatim,
    /// so rendered output is unchanged.
    private static func rebuild(
        _ document: PDFDocument,
        stripAnnotations: Bool,
        clearMetadata: Bool
    ) -> PDFDocument {
        let fresh = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            if stripAnnotations {
                for annotation in page.annotations {
                    page.removeAnnotation(annotation)
                }
            }
            fresh.insert(page, at: fresh.pageCount)
        }
        if clearMetadata {
            fresh.documentAttributes = [:]
        } else {
            fresh.documentAttributes = document.documentAttributes
        }
        return fresh
    }
}
