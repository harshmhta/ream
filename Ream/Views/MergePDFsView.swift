import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// File → Merge PDFs… — pick N files, reorder them, toggle interleave, and
/// merge into a single new file via one button.
struct MergePDFsView: View {
    @ObservedObject var controller: PageOpsController
    @Environment(\.dismiss) private var dismiss

    /// A source file plus a cached page count for the row subtitle.
    struct Source: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let pageCount: Int
    }

    @State private var sources: [Source] = []
    @State private var includeCurrent = true
    @State private var interleave = false
    @State private var selection: Source.ID?

    private var currentPageCount: Int { controller.document.pdfDocument.pageCount }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            options
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 440)
        .onExitCommand { dismiss() }
        .onAppear {
            if sources.isEmpty { addFiles() }
        }
    }

    private var header: some View {
        HStack {
            Text("Merge PDFs").font(.headline)
            Spacer()
            Text("\(totalPages) page\(totalPages == 1 ? "" : "s") total")
                .foregroundStyle(.secondary).font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var totalPages: Int {
        (includeCurrent ? currentPageCount : 0) + sources.reduce(0) { $0 + $1.pageCount }
    }

    private var list: some View {
        List(selection: $selection) {
            if includeCurrent {
                HStack {
                    Image(systemName: "doc.text.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(currentDocName).fontWeight(.medium)
                        Text("\(currentPageCount) pages · current document").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .selectionDisabled()
            }
            ForEach(sources) { source in
                HStack {
                    Image(systemName: "doc.text")
                    VStack(alignment: .leading) {
                        Text(source.url.lastPathComponent)
                        Text("\(source.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .tag(source.id)
            }
            .onMove { indices, dest in sources.move(fromOffsets: indices, toOffset: dest) }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var currentDocName: String {
        controller.document.pdfDocument.documentURL?.lastPathComponent ?? "Current Document"
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include current document (first)", isOn: $includeCurrent)
            Toggle(isOn: $interleave) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interleave pages")
                    Text("Round-robin pages across files — for duplex scans split into odd/even files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
            Button(role: .destructive) { removeSelected() } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection == nil)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Merge…") { merge() }
                .keyboardShortcut(.defaultAction)
                .disabled(totalPages == 0 || (sources.isEmpty && !includeCurrent))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Actions

    private func addFiles() {
        let urls = controller.chooseFiles(types: [.pdf], message: "Choose PDFs to merge.")
        for url in urls where !sources.contains(where: { $0.url == url }) {
            let count = PDFDocument(url: url)?.pageCount ?? 0
            sources.append(Source(url: url, pageCount: count))
        }
    }

    private func removeSelected() {
        guard let selection else { return }
        sources.removeAll { $0.id == selection }
        self.selection = nil
    }

    private func merge() {
        let urls = sources.map(\.url)
        dismiss()
        controller.performMerge(urls: urls, interleave: interleave, includeCurrent: includeCurrent)
    }
}
