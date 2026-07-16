import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// The "Manage Pages" thumbnail grid — reorder, rotate, delete, duplicate, and
/// extract pages of the current document.
///
/// Selection model mirrors Finder: click selects one, ⌘-click toggles, ⇧-click
/// extends a range from the anchor, ⌘A selects all. Drag a selection onto a gap
/// to reorder. The context menu exposes rotate/delete/duplicate/extract, all of
/// which route through ``PageOpsController`` so they are undoable.
struct ManagePagesView: View {
    @ObservedObject var document: PDFReferenceDocument
    @ObservedObject var controller: PageOpsController
    @StateObject private var thumbnails = PageThumbnailCache()
    @Environment(\.dismiss) private var dismiss

    /// 0-based indices of selected pages.
    @State private var selection: Set<Int> = []
    /// Anchor for ⇧-click range selection.
    @State private var anchor: Int?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)]
    private let thumbMaxDimension: CGFloat = 150

    private var pageCount: Int { document.pdfDocument.pageCount }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 460)
        .onExitCommand { dismiss() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Manage Pages")
                .font(.headline)
            Spacer()
            Text(selection.isEmpty
                 ? "\(pageCount) page\(pageCount == 1 ? "" : "s")"
                 : "\(selection.count) selected")
                .foregroundStyle(.secondary)
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(0..<pageCount, id: \.self) { index in
                    if let page = document.pdfDocument.page(at: index) {
                        cell(page: page, index: index)
                    }
                }
            }
            .padding(20)
        }
        // Click empty space to clear selection.
        .background(
            Color.clear.contentShape(Rectangle()).onTapGesture { selection = []; anchor = nil }
        )
        .onDeleteCommand(perform: selection.isEmpty ? nil : deleteSelected)
        // ⌘A — select all.
        .background(
            Button("") { selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .hidden()
        )
    }

    private func cell(page: PDFPage, index: Int) -> some View {
        let isSelected = selection.contains(index)
        return VStack(spacing: 6) {
            Image(nsImage: thumbnails.thumbnail(for: page,
                                                generation: document.pageGeneration,
                                                maxDimension: thumbMaxDimension))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: thumbMaxDimension, maxHeight: thumbMaxDimension)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                      lineWidth: isSelected ? 3 : 1)
                )
                .shadow(radius: 1, y: 1)

            Text("\(index + 1)")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { handleClick(index: index) }
        .draggable(PageDragPayload(index: index)) {
            // Drag preview.
            Image(nsImage: thumbnails.thumbnail(for: page,
                                                generation: document.pageGeneration,
                                                maxDimension: 80))
                .resizable().aspectRatio(contentMode: .fit).frame(width: 60)
        }
        .dropDestination(for: PageDragPayload.self) { payloads, _ in
            handleDrop(payloads: payloads, targetIndex: index)
        }
        .contextMenu { contextMenu(for: index) }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for index: Int) -> some View {
        // Operate on the full selection if the right-clicked page is part of it,
        // otherwise just the clicked page.
        let targets = selection.contains(index) ? selection : [index]

        Button("Rotate 90° Clockwise") { controller.rotate(IndexSet(targets), clockwise: true) }
        Button("Rotate 90° Counterclockwise") { controller.rotate(IndexSet(targets), clockwise: false) }
        Divider()
        Button("Duplicate") { controller.duplicate(IndexSet(targets)) }
        Button("Extract to New File…") { controller.performExtract(pageIndices: Array(targets)) }
        Divider()
        Button("Delete", role: .destructive) {
            controller.delete(IndexSet(targets))
            selection = []
        }
        .disabled(targets.count >= pageCount)
    }

    // MARK: - Footer (toolbar of actions)

    private var footer: some View {
        HStack(spacing: 12) {
            Button { controller.rotate(activeIndices(), clockwise: false) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            Button { controller.rotate(activeIndices(), clockwise: true) } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            Button { controller.duplicate(activeIndices()) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                controller.delete(activeIndices()); selection = []
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty || selection.count >= pageCount)

            Divider().frame(height: 18)

            Button { controller.performExtract(pageIndices: Array(selection)) } label: {
                Label("Extract…", systemImage: "square.and.arrow.up")
            }
            .disabled(selection.isEmpty)

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .labelStyle(.titleAndIcon)
        .disabled(pageCount == 0)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The indices footer buttons act on: the selection, or all pages when
    /// nothing is selected (so a toolbar rotate does something useful).
    private func activeIndices() -> IndexSet {
        selection.isEmpty ? IndexSet(0..<pageCount) : IndexSet(selection)
    }

    // MARK: - Selection handling

    private func handleClick(index: Int) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
            anchor = index
        } else if modifiers.contains(.shift), let anchor {
            let range = min(anchor, index)...max(anchor, index)
            selection = Set(range)
        } else {
            selection = [index]
            anchor = index
        }
    }

    private func selectAll() {
        selection = Set(0..<pageCount)
    }

    private func deleteSelected() {
        guard !selection.isEmpty, selection.count < pageCount else { return }
        controller.delete(IndexSet(selection))
        selection = []
    }

    // MARK: - Drag & drop reorder

    private func handleDrop(payloads: [PageDragPayload], targetIndex: Int) -> Bool {
        let sources = payloads.map(\.index)
        guard !sources.isEmpty else { return false }
        // If the dragged page is part of the current selection, move the whole
        // selection; otherwise move just the dragged page(s).
        let moving = sources.contains(where: selection.contains) ? selection : Set(sources)
        // Drop lands *before* the target page.
        controller.move(IndexSet(moving), to: targetIndex)
        selection = []
        anchor = nil
        return true
    }
}

/// Transferable payload identifying a dragged page by its current index.
struct PageDragPayload: Codable, Transferable {
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .reamPageDrag)
    }
}

extension UTType {
    /// Private drag type for reordering pages within the Manage Pages grid.
    static let reamPageDrag = UTType(exportedAs: "com.ream.page-drag")
}
