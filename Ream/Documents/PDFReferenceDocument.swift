import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import ReamCore

/// The document model backing every open PDF.
///
/// We adopt `ReferenceFileDocument` (a reference type) rather than the value-type
/// `FileDocument` because `PDFKit.PDFDocument` is a reference type and we want a
/// single shared instance per window that views and view models can mutate in
/// place. Phase 2 metadata + security operations mutate `pdfDocument` (or replace
/// it with a rebuilt copy) and register undo actions so SwiftUI autosave/Versions
/// persist the change through ``snapshot(contentType:)``.
///
/// ## Persistence & "store nothing"
/// Encryption is applied lazily at save time from an **in-memory**
/// ``EncryptionSettings``. Passwords live only in this object for the window's
/// lifetime and are never written anywhere except as the encrypted PDF bytes
/// themselves — honoring the scope's "store nothing" rule.
final class PDFReferenceDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    /// The PDFKit document being displayed. Replaced wholesale by operations that
    /// must rebuild the page tree (strip, remove-password); mutated in place for
    /// metadata edits.
    @Published var pdfDocument: PDFKit.PDFDocument

    /// Pending encryption to apply on the next save. `nil` means "save as
    /// plaintext". Held in memory only — see the type doc.
    @Published private(set) var encryptionSettings: EncryptionSettings?

    /// Monotonic counter bumped on every in-place page mutation. Views and the
    /// thumbnail cache observe it to invalidate derived state (thumbnails, page
    /// rows) without tracking which specific pages changed.
    @Published private(set) var pageGeneration: Int = 0

    /// Bump the mutation generation. Called by the page-ops extension after each
    /// structural edit so observers refresh.
    func bumpPageGeneration() {
        pageGeneration &+= 1
    }

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
        // A locked (encrypted) document loads successfully but reports
        // `isLocked == true`; the UI prompts for the open password. We do not
        // treat that as a read error.
        //
        // Set the annotation delegate before anything reads `page.annotations`,
        // so Ream's non-native subtypes (Squiggly/Polygon/PolyLine) parse back
        // as their editable subclasses. PDFKit parses annotations lazily, so
        // installing it here (pre-display) is early enough.
        doc.delegate = AnnotationDocumentDelegate.shared
        self.pdfDocument = doc
    }

    /// Notify SwiftUI + the document architecture that annotations mutated in
    /// place, so autosave/Versions captures a fresh snapshot. In-place PDFKit
    /// edits (adding/removing annotations) don't touch a `@Published` property,
    /// so the change publisher has to be fired manually.
    func annotationsDidChange() {
        objectWillChange.send()
    }

    /// Snapshot the current bytes so autosave/versions can persist them.
    ///
    /// - When ``encryptionSettings`` is set, emits encrypted bytes (AES-128, the
    ///   strongest the native writer supports — see ``PDFSecurityService``).
    /// - Otherwise returns the document's current representation, which reflects
    ///   any in-place metadata edits, added annotations, or a prior
    ///   strip/remove-password rebuild.
    ///
    /// For an untouched document this is the same byte-stable no-op round-trip
    /// the foundation shipped — we only diverge when the user explicitly edits.
    /// Once annotations exist, PDFKit rewrites the file to include them (still
    /// non-destructive to the original page content).
    func snapshot(contentType: UTType) throws -> Data {
        if let settings = encryptionSettings, settings.hasAnyPassword {
            return try PDFSecurityService.encryptedData(from: pdfDocument, settings: settings)
        }
        guard let data = pdfDocument.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    // MARK: - Locked-document handling

    /// Whether the document is currently encrypted and locked (needs a password
    /// to view).
    var isLocked: Bool { pdfDocument.isLocked }

    /// Attempt to unlock a locked document with `password`. On success the view
    /// refreshes to show the pages. Returns whether the document is now unlocked.
    @discardableResult
    func unlock(withPassword password: String) -> Bool {
        guard pdfDocument.isLocked else { return true }
        objectWillChange.send()
        let unlocked = pdfDocument.unlock(withPassword: password)
        return unlocked
    }

    // MARK: - Metadata

    /// The current Info-dictionary metadata as a portable value.
    var metadata: DocumentMetadata { PDFMetadataService.read(from: pdfDocument) }

    /// Apply edited metadata and mark the document dirty (undoable).
    func updateMetadata(_ metadata: DocumentMetadata, undoManager: UndoManager?) {
        let previous = PDFMetadataService.read(from: pdfDocument)
        registerUndo(undoManager, previousMetadata: previous)
        objectWillChange.send()
        PDFMetadataService.apply(metadata, to: pdfDocument)
    }

    private func registerUndo(_ undoManager: UndoManager?, previousMetadata: DocumentMetadata) {
        undoManager?.registerUndo(withTarget: self) { document in
            document.updateMetadata(previousMetadata, undoManager: undoManager)
        }
        undoManager?.setActionName("Edit Document Properties")
    }

    // MARK: - Strip all metadata

    /// Replace the document with a fully metadata-scrubbed rebuild (Info dict,
    /// XMP, thumbnails, annotations, prior versions removed). Undoable.
    func stripAllMetadata(undoManager: UndoManager?) throws {
        guard !pdfDocument.isLocked else { throw PDFSecurityService.SecurityError.documentLocked }
        let previous = pdfDocument
        let previousSettings = encryptionSettings
        let stripped = try PDFSecurityService.strippedDocument(from: pdfDocument)

        undoManager?.registerUndo(withTarget: self) { document in
            document.restore(document: previous, encryption: previousSettings, undoManager: undoManager)
        }
        undoManager?.setActionName("Strip All Metadata")

        objectWillChange.send()
        pdfDocument = stripped
    }

    // MARK: - Encrypt

    /// Set (or clear) the encryption applied on the next save. Undoable.
    func setEncryption(_ settings: EncryptionSettings?, undoManager: UndoManager?) {
        let previous = encryptionSettings
        undoManager?.registerUndo(withTarget: self) { document in
            document.setEncryption(previous, undoManager: undoManager)
        }
        undoManager?.setActionName("Encrypt Document")
        objectWillChange.send()
        encryptionSettings = (settings?.hasAnyPassword ?? false) ? settings?.normalized : nil
    }

    // MARK: - Remove password

    /// Whether removing the password is possible right now: the document is
    /// either currently marked for encryption, or it was opened from an encrypted
    /// file and is now unlocked (so we hold decrypted content in memory).
    var canRemovePassword: Bool {
        if encryptionSettings != nil { return true }
        return pdfDocument.isEncrypted && !pdfDocument.isLocked
    }

    /// Write an unencrypted copy: clears pending encryption and, if the loaded
    /// document itself is encrypted, rebuilds it into plaintext. Undoable.
    func removePassword(undoManager: UndoManager?) throws {
        guard canRemovePassword else { return }
        guard !pdfDocument.isLocked else { throw PDFSecurityService.SecurityError.documentLocked }

        let previousDocument = pdfDocument
        let previousSettings = encryptionSettings

        undoManager?.registerUndo(withTarget: self) { document in
            document.restore(document: previousDocument, encryption: previousSettings, undoManager: undoManager)
        }
        undoManager?.setActionName("Remove Password")

        objectWillChange.send()
        encryptionSettings = nil
        if pdfDocument.isEncrypted {
            pdfDocument = try PDFSecurityService.decryptedDocument(from: pdfDocument)
        }
    }

    /// Undo helper: restore a prior document + encryption state in one step.
    private func restore(document: PDFKit.PDFDocument, encryption: EncryptionSettings?, undoManager: UndoManager?) {
        let currentDocument = pdfDocument
        let currentSettings = encryptionSettings
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.restore(document: currentDocument, encryption: currentSettings, undoManager: undoManager)
        }
        objectWillChange.send()
        pdfDocument = document
        encryptionSettings = encryption
    }
}
