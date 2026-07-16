import SwiftUI
import PDFKit
import ReamCore

/// File → Document Properties (⌘I).
///
/// Editable Info-dictionary fields (Title, Author, Subject, Keywords, Created,
/// Modified, PDF Producer, Application) plus read-only stats (page count, file
/// size, PDF version, tagged/linearized/encrypted) and an advanced disclosure
/// showing the raw XMP metadata as a key/value list.
struct DocumentPropertiesView: View {
    @ObservedObject var document: PDFReferenceDocument
    let fileURL: URL?
    /// Called when the user taps "Strip All Metadata…" so the parent can chain
    /// to the dedicated confirmation sheet after this one dismisses.
    let onStripRequested: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    // Editable fields.
    @State private var title = ""
    @State private var author = ""
    @State private var subject = ""
    @State private var keywords = ""
    @State private var creator = ""
    @State private var producer = ""
    @State private var creationDate: Date?
    @State private var modificationDate: Date?

    // Read-only / advanced.
    @State private var stats: PDFDocumentStats?
    @State private var xmpEntries: [PDFXMPService.XMPEntry] = []
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    editableSection
                    Divider()
                    statsSection
                    if !xmpEntries.isEmpty {
                        Divider()
                        xmpSection
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .onAppear(perform: load)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Document Properties")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Button("Strip All Metadata…", role: .destructive) {
                // Defer to the dedicated confirmation sheet after we dismiss.
                dismiss()
                onStripRequested()
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Editable fields

    private var editableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Title", text: $title)
            labeledField("Author", text: $author)
            labeledField("Subject", text: $subject)
            labeledField("Keywords", text: $keywords, prompt: "Comma-separated")
            labeledField("Application", text: $creator, prompt: "Creating application")
            labeledField("PDF Producer", text: $producer)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                fieldLabel("Created")
                Text(displayDate(creationDate))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                fieldLabel("Modified")
                Text(displayDate(modificationDate))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, prompt: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            fieldLabel(label)
            TextField(prompt ?? "", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .frame(width: 110, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.subheadline.weight(.semibold))
            if let stats {
                statRow("Pages", "\(stats.pageCount)")
                statRow("File size", stats.fileSizeDisplay)
                statRow("PDF version", stats.pdfVersion)
                statRow("Tagged", stats.isTagged ? "Yes" : "No")
                statRow("Linearized", stats.isLinearized ? "Yes" : "No")
                statRow("Encrypted", stats.isEncrypted ? "Yes" : "No")
            } else {
                Text("Reading…").foregroundStyle(.secondary)
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .frame(maxWidth: 320, alignment: .leading)
    }

    // MARK: - XMP

    private var xmpSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(xmpEntries) { entry in
                    HStack(alignment: .top) {
                        Text(entry.key)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .trailing)
                        Text(entry.value)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced — XMP Metadata (\(xmpEntries.count))")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Data flow

    private func load() {
        let metadata = document.metadata
        title = metadata.title ?? ""
        author = metadata.author ?? ""
        subject = metadata.subject ?? ""
        keywords = metadata.keywords.joined(separator: ", ")
        creator = metadata.creator ?? ""
        producer = metadata.producer ?? ""
        creationDate = metadata.creationDate
        modificationDate = metadata.modificationDate

        stats = PDFStatsService.stats(for: document.pdfDocument, fileURL: fileURL)
        xmpEntries = PDFXMPService.entries(from: document.pdfDocument)
    }

    private func save() {
        let parsedKeywords = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let updated = DocumentMetadata(
            title: title.trimmingCharacters(in: .whitespaces),
            author: author.trimmingCharacters(in: .whitespaces),
            subject: subject.trimmingCharacters(in: .whitespaces),
            keywords: parsedKeywords,
            creator: creator.trimmingCharacters(in: .whitespaces),
            producer: producer.trimmingCharacters(in: .whitespaces),
            creationDate: creationDate,
            modificationDate: modificationDate
        )
        document.updateMetadata(updated, undoManager: undoManager)
        dismiss()
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
