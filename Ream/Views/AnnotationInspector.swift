import SwiftUI
import PDFKit

/// The right-hand annotation list. Lists every annotation with a type icon,
/// page, text snippet, author, and timestamp; supports filtering by type /
/// author / page, click-to-jump, and bulk delete.
struct AnnotationInspector: View {
    @ObservedObject var controller: AnnotationController

    @State private var typeFilter: String = "All"
    @State private var authorFilter: String = "All"
    @State private var pageFilter: String = "All"

    // Recomputed whenever the controller's revision changes.
    private var rows: [Row] {
        _ = controller.revision   // dependency
        return controller.allAnnotations().map { Row(page: $0.page, annotation: $0.annotation) }
    }

    private var filtered: [Row] {
        rows.filter { row in
            (typeFilter == "All" || row.typeLabel == typeFilter)
                && (authorFilter == "All" || row.author == authorFilter)
                && (pageFilter == "All" || "Page \(row.page + 1)" == pageFilter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 288)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Annotations").font(.headline)
            Spacer()
            Text("\(rows.count)").foregroundStyle(.secondary).font(.callout.monospacedDigit())
            Menu {
                Button("Delete All", role: .destructive) { deleteAll() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var filters: some View {
        HStack(spacing: 8) {
            filterMenu("Type", selection: $typeFilter, options: ["All"] + Set(rows.map(\.typeLabel)).sorted())
            filterMenu("Author", selection: $authorFilter, options: ["All"] + Set(rows.map(\.author)).sorted())
            filterMenu("Page", selection: $pageFilter, options: ["All"] + Set(rows.map { "Page \($0.page + 1)" }).sorted())
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func filterMenu(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { selection.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 2) {
                Text(selection.wrappedValue == "All" ? label : selection.wrappedValue)
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var list: some View {
        List(filtered, selection: Binding(
            get: { controller.selectedAnnotation?.storedReamID },
            set: { id in
                controller.selectedAnnotation = filtered.first { $0.id == id }?.annotation
            })
        ) { row in
            AnnotationRowView(row: row)
                .contentShape(Rectangle())
                .onTapGesture { controller.reveal(row.annotation) }
                .contextMenu {
                    Button("Jump to") { controller.reveal(row.annotation) }
                    if row.canResolve {
                        Button(row.annotation.reamResolved ? "Mark Unresolved" : "Mark Resolved") {
                            row.annotation.reamResolved.toggle()
                            controller.didChange()
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { controller.remove(row.annotation) }
                }
                .tag(row.id)
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.badge.plus").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("No annotations yet").foregroundStyle(.secondary).font(.callout)
            Text("Use the toolbar to highlight, note, draw, or stamp.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }

    private func deleteAll() {
        for row in filtered { controller.remove(row.annotation) }
    }

    // MARK: Row model

    struct Row: Identifiable {
        let page: Int
        let annotation: PDFAnnotation
        var id: String? { annotation.storedReamID }

        var typeLabel: String {
            switch annotation.type ?? "" {
            case "Highlight": return "Highlight"
            case "Underline": return "Underline"
            case "StrikeOut": return "Strikethrough"
            case "Squiggly": return "Squiggly"
            case "Text": return "Note"
            case "Ink": return "Ink"
            case "Square": return "Rectangle"
            case "Circle": return "Ellipse"
            case "Line": return "Line"
            case "Polygon": return "Polygon"
            case "PolyLine": return "Polyline"
            case "FreeText": return "Text"
            case "Stamp": return "Stamp"
            default: return annotation.type ?? "Annotation"
            }
        }

        var author: String { annotation.userName ?? "Unknown" }
        var canResolve: Bool { annotation.type == "Text" }

        var snippet: String {
            if let contents = annotation.contents, !contents.isEmpty { return contents }
            if annotation.reamInReplyTo != nil { return "↳ reply" }
            return typeLabel
        }

        var icon: String {
            switch annotation.type ?? "" {
            case "Highlight": return "highlighter"
            case "Underline", "Squiggly": return "underline"
            case "StrikeOut": return "strikethrough"
            case "Text": return "note.text"
            case "Ink": return "scribble"
            case "Square": return "rectangle"
            case "Circle": return "circle"
            case "Line": return "line.diagonal"
            case "Polygon": return "pentagon"
            case "PolyLine": return "scribble.variable"
            case "FreeText": return "textformat"
            case "Stamp": return "checkmark.seal"
            default: return "mappin"
            }
        }
    }
}

private struct AnnotationRowView: View {
    let row: AnnotationInspector.Row

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: row.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.snippet).lineLimit(1)
                    if row.annotation.reamResolved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption2)
                    }
                }
                HStack(spacing: 6) {
                    Text("Page \(row.page + 1)")
                    Text("·")
                    Text(row.author).lineLimit(1)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
