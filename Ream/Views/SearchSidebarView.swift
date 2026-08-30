import SwiftUI
import AppKit

/// The search sidebar: a query field with case / whole-word / regex toggles and
/// a virtualized results list. Each row shows the page number and a one-line
/// preview with the hit emphasised; clicking a row jumps to and highlights it.
struct SearchSidebarView: View {
    @ObservedObject var search: SearchService
    /// Bound so ⌘F can move keyboard focus into the field.
    var fieldFocus: FocusState<Bool>.Binding
    let onSelect: (SearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchControls
            Divider()
            resultsList
        }
    }

    private var searchControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search document", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused(fieldFocus)
                    .onSubmit { search.focusNext() }
                if !search.query.isEmpty {
                    Button {
                        search.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 6) {
                toggle("textformat", "Case sensitive", isOn: $search.options.caseSensitive)
                toggle("character.textbox", "Whole word", isOn: $search.options.wholeWord)
                toggle("asterisk", "Regular expression", isOn: $search.options.regex)
                Spacer()
                resultCountLabel
            }
        }
        .padding(10)
    }

    private func toggle(_ icon: String, _ help: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Image(systemName: icon)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    @ViewBuilder
    private var resultCountLabel: some View {
        if search.isSearching {
            ProgressView().controlSize(.small)
        } else if !search.query.isEmpty {
            Text("\(search.resultCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if search.query.isEmpty {
            SidebarEmptyState(icon: "magnifyingglass",
                              message: "Type to search the document.")
        } else if search.results.isEmpty && !search.isSearching {
            SidebarEmptyState(icon: "questionmark.circle",
                              message: "No matches.")
        } else {
            ScrollViewReader { proxy in
                List(Array(search.results.enumerated()), id: \.element.id) { index, result in
                    SearchResultRow(result: result,
                                    isCurrent: index == search.currentIndex)
                        .id(result.id)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(result) }
                }
                .listStyle(.inset)
                .onChange(of: search.currentIndex) { _, newValue in
                    if let idx = newValue, idx < search.results.count {
                        withAnimation { proxy.scrollTo(search.results[idx].id, anchor: .center) }
                    }
                }
            }
        }
    }
}

/// One search result row: page badge + preview with the hit emphasised.
private struct SearchResultRow: View {
    let result: SearchResult
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(result.pageIndex + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            Text(previewAttributed)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// Emphasise the matched substring within the preview line.
    private var previewAttributed: AttributedString {
        var attributed = AttributedString(result.preview)
        let ns = result.preview as NSString
        let r = result.previewMatchRange
        guard r.location != NSNotFound, r.location >= 0, r.length > 0,
              r.location + r.length <= ns.length,
              let strRange = Range(r, in: result.preview) else {
            return attributed
        }
        // Map the String range onto AttributedString via character offsets.
        let startOffset = result.preview.distance(from: result.preview.startIndex, to: strRange.lowerBound)
        let length = result.preview.distance(from: strRange.lowerBound, to: strRange.upperBound)
        let lo = attributed.index(attributed.startIndex, offsetByCharacters: startOffset)
        let hi = attributed.index(lo, offsetByCharacters: length)
        attributed[lo..<hi].font = .callout.bold()
        attributed[lo..<hi].foregroundColor = .primary
        return attributed
    }
}
