import SwiftUI
import ReamCore

/// Confirmation sheet for File → Strip All Metadata.
///
/// Lists exactly what will be removed (per the scope's requirement that the
/// confirmation "list exactly what will be removed") before performing the
/// destructive scrub. The current identifying fields are shown so the user sees
/// what is about to be wiped.
struct StripMetadataView: View {
    @ObservedObject var document: PDFReferenceDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    let onError: (Error) -> Void

    private var metadata: DocumentMetadata { document.metadata }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    removedList
                    if !metadata.identifyingFields.isEmpty {
                        currentValues
                    }
                    caveat
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        HStack {
            Image(systemName: "eraser.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Strip All Metadata")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Strip Metadata", role: .destructive) { strip() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var intro: some View {
        Text("This permanently removes hidden and identifying data from a rebuilt copy of the document. The visible page content is unchanged.")
            .fixedSize(horizontal: false, vertical: true)
    }

    private var removedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Will be removed:")
                .font(.subheadline.weight(.semibold))
            bullet("Document information (Title, Author, Subject, Keywords, Application)")
            bullet("XMP metadata")
            bullet("Embedded page thumbnails")
            bullet("Annotations and comments")
            bullet("Prior incremental-save versions")
        }
    }

    private var currentValues: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Current values that will be lost:")
                .font(.subheadline.weight(.semibold))
            ForEach(metadata.identifyingFields, id: \.label) { field in
                HStack(alignment: .top) {
                    Text(field.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(field.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }

    private var caveat: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This also removes the document outline (bookmarks) and any file attachments, because the file is fully rewritten.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("You can undo this with ⌘Z before saving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func strip() {
        do {
            try document.stripAllMetadata(undoManager: undoManager)
            dismiss()
        } catch {
            dismiss()
            onError(error)
        }
    }
}
