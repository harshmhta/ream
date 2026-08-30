import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// File → Insert Pages… — add blank pages, pages from another PDF, or pages
/// built from images, at a chosen position in the current document.
struct InsertPagesView: View {
    @ObservedObject var controller: PageOpsController
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case blank = "Blank page"
        case fromPDF = "From PDF…"
        case fromImages = "From images…"
        var id: String { rawValue }
    }

    enum Position: String, CaseIterable, Identifiable {
        case beginning = "At beginning"
        case end = "At end"
        case afterPage = "After page"
        var id: String { rawValue }
    }

    enum BlankPaper: String, CaseIterable, Identifiable {
        case matchCurrent = "Match current page"
        case usLetter = "US Letter"
        case a4 = "A4"
        var id: String { rawValue }
    }

    @State private var source: Source = .blank
    @State private var position: Position = .end
    @State private var afterPage: Int = 1
    @State private var blankPaper: BlankPaper = .matchCurrent

    private var pageCount: Int { controller.document.pdfDocument.pageCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 460)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        Text("Insert Pages").font(.headline)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("What to insert", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }

            if source == .blank {
                Picker("Page size", selection: $blankPaper) {
                    ForEach(BlankPaper.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Divider()

            Picker("Where", selection: $position) {
                ForEach(Position.allCases) { Text($0.rawValue).tag($0) }
            }
            if position == .afterPage {
                Stepper(value: $afterPage, in: 1...max(1, pageCount)) {
                    Text("After page \(afterPage)")
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Insert") { insert() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// 0-based insertion index derived from the chosen position.
    private var insertionIndex: Int {
        switch position {
        case .beginning: return 0
        case .end: return pageCount
        case .afterPage: return min(afterPage, pageCount)
        }
    }

    private func insert() {
        let index = insertionIndex
        switch source {
        case .blank:
            controller.insertBlank(size: blankSize(), at: index)
            dismiss()
        case .fromPDF:
            let urls = controller.chooseFiles(types: [.pdf], message: "Choose PDFs to insert.")
            guard !urls.isEmpty else { return }
            dismiss()
            controller.insertPages(fromPDFs: urls, at: index)
        case .fromImages:
            let urls = controller.chooseFiles(types: [.png, .jpeg, .tiff, .heic, .gif, .bmp],
                                              message: "Choose images to insert as pages.")
            guard !urls.isEmpty else { return }
            dismiss()
            controller.insertPages(fromImages: urls, at: index)
        }
    }

    private func blankSize() -> CGSize {
        switch blankPaper {
        case .usLetter: return PageOperations.BlankSize.usLetter
        case .a4: return PageOperations.BlankSize.a4
        case .matchCurrent:
            if let page = controller.document.pdfDocument.page(at: max(0, insertionIndex - 1))
                ?? controller.document.pdfDocument.page(at: 0) {
                let bounds = page.bounds(for: .mediaBox)
                if bounds.width > 0, bounds.height > 0 { return bounds.size }
            }
            return PageOperations.BlankSize.usLetter
        }
    }
}
