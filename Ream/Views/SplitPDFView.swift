import SwiftUI
import PDFKit

/// File → Split PDF… — split the current document by page ranges, every N
/// pages, or at top-level bookmarks. Writes one file per part into a chosen
/// folder.
struct SplitPDFView: View {
    @ObservedObject var controller: PageOpsController
    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable, Identifiable {
        case ranges = "By page ranges"
        case everyN = "Every N pages"
        case bookmarks = "By bookmarks"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .ranges
    @State private var rangeSpec: String = ""
    @State private var everyN: Int = 1
    @State private var rangeError: String?

    private var pageCount: Int { controller.document.pdfDocument.pageCount }
    private var hasBookmarks: Bool {
        (controller.document.pdfDocument.outlineRoot?.numberOfChildren ?? 0) > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 480)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack {
            Text("Split PDF").font(.headline)
            Spacer()
            Text("\(pageCount) pages").foregroundStyle(.secondary).font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .ranges:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Page ranges").font(.subheadline).fontWeight(.medium)
                    TextField("e.g. 1-3, 7, 10-", text: $rangeSpec)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: rangeSpec) { _, _ in rangeError = nil }
                    Text("Comma-separate segments; each becomes its own file. Open ranges like “10-” run to the end.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let rangeError {
                        Text(rangeError).font(.caption).foregroundStyle(.red)
                    }
                }
            case .everyN:
                VStack(alignment: .leading, spacing: 6) {
                    Stepper(value: $everyN, in: 1...max(1, pageCount)) {
                        Text("Every \(everyN) page\(everyN == 1 ? "" : "s")")
                    }
                    Text("Produces \(chunkCount) file\(chunkCount == 1 ? "" : "s").")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .bookmarks:
                VStack(alignment: .leading, spacing: 6) {
                    if hasBookmarks {
                        Text("Splits at each top-level bookmark.")
                            .font(.subheadline)
                    } else {
                        Label("This document has no top-level bookmarks.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
    }

    private var chunkCount: Int {
        guard everyN > 0, pageCount > 0 else { return 0 }
        return (pageCount + everyN - 1) / everyN
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Split…") { split() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSplit)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var canSplit: Bool {
        guard pageCount > 0 else { return false }
        switch mode {
        case .ranges: return !rangeSpec.trimmingCharacters(in: .whitespaces).isEmpty
        case .everyN: return everyN >= 1
        case .bookmarks: return hasBookmarks
        }
    }

    private func split() {
        switch mode {
        case .ranges:
            // Validate up front so the error shows inline rather than as an alert.
            do {
                _ = try PageOperations.parsePageRanges(rangeSpec, pageCount: pageCount)
            } catch {
                rangeError = error.localizedDescription
                return
            }
            dismiss()
            controller.performSplit(mode: .ranges(rangeSpec))
        case .everyN:
            dismiss()
            controller.performSplit(mode: .everyN(everyN))
        case .bookmarks:
            dismiss()
            controller.performSplit(mode: .bookmarks)
        }
    }
}
