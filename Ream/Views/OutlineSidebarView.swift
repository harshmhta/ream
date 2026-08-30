import SwiftUI
import PDFKit

/// A node in the document's outline (bookmarks) tree, adapted for SwiftUI.
///
/// `PDFOutline` is an AppKit tree of reference-type nodes; `OutlineGroup` wants
/// value-type `Identifiable` items with an optional `children` array. This
/// bridges the two, capturing each node's label and its jump destination.
struct OutlineNode: Identifiable {
    let id = UUID()
    let label: String
    /// Zero-based page index to jump to, if the node has a destination.
    let pageIndex: Int?
    let children: [OutlineNode]?

    /// Build the SwiftUI node tree from a `PDFOutline` root. Returns `nil` if the
    /// document has no outline.
    static func tree(from root: PDFOutline?, document: PDFDocument) -> [OutlineNode]? {
        guard let root, root.numberOfChildren > 0 else { return nil }
        return (0..<root.numberOfChildren).compactMap { i in
            node(from: root.child(at: i), document: document)
        }
    }

    private static func node(from outline: PDFOutline?, document: PDFDocument) -> OutlineNode? {
        guard let outline else { return nil }
        let childCount = outline.numberOfChildren
        let children: [OutlineNode]? = childCount > 0
            ? (0..<childCount).compactMap { node(from: outline.child(at: $0), document: document) }
            : nil

        var pageIndex: Int?
        if let page = outline.destination?.page ?? outline.action.flatMap(destinationPage) {
            let idx = document.index(for: page)
            if idx >= 0 { pageIndex = idx }
        }
        return OutlineNode(label: outline.label ?? "Untitled",
                           pageIndex: pageIndex,
                           children: children)
    }

    /// Some outlines carry a `PDFActionGoTo` rather than a plain destination.
    private static func destinationPage(_ action: PDFAction) -> PDFPage? {
        (action as? PDFActionGoTo)?.destination.page
    }
}

/// The outline / bookmarks sidebar: an expandable tree the user clicks to jump.
struct OutlineSidebarView: View {
    let nodes: [OutlineNode]?
    let onSelect: (Int) -> Void

    var body: some View {
        if let nodes, !nodes.isEmpty {
            List {
                OutlineGroup(nodes, children: \.children) { node in
                    Button {
                        if let page = node.pageIndex { onSelect(page) }
                    } label: {
                        HStack {
                            Text(node.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(node.pageIndex == nil)
                }
            }
            .listStyle(.sidebar)
        } else {
            SidebarEmptyState(icon: "list.bullet.indent",
                              message: "This document has no outline.")
        }
    }
}

/// Shared placeholder shown when a sidebar mode has nothing to display.
struct SidebarEmptyState: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
