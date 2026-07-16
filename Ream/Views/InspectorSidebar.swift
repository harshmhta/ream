import SwiftUI
import PDFKit

/// The three modes the single left inspector switches between.
enum InspectorMode: Int, CaseIterable, Identifiable {
    case thumbnails
    case outline
    case search

    var id: Int { rawValue }

    var symbol: String {
        switch self {
        case .thumbnails: return "square.grid.2x2"
        case .outline:    return "list.bullet.indent"
        case .search:     return "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .outline:    return "Outline"
        case .search:     return "Search"
        }
    }
}

/// One left inspector that switches between Thumbnails / Outline / Search via a
/// segmented control at the top — the "one left inspector that switches modes"
/// from the brief.
struct InspectorSidebar: View {
    @Binding var mode: InspectorMode
    let pdfView: PDFView?
    let outlineNodes: [OutlineNode]?
    @ObservedObject var search: SearchService
    var searchFieldFocus: FocusState<Bool>.Binding
    let onJumpToPage: (Int) -> Void
    let onSelectResult: (SearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(InspectorMode.allCases) { mode in
                    Image(systemName: mode.symbol)
                        .help(mode.label)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 200, idealWidth: 260)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .thumbnails:
            ThumbnailSidebarView(pdfView: pdfView)
        case .outline:
            OutlineSidebarView(nodes: outlineNodes, onSelect: onJumpToPage)
        case .search:
            SearchSidebarView(search: search,
                              fieldFocus: searchFieldFocus,
                              onSelect: onSelectResult)
        }
    }
}
