import Foundation

/// Options controlling a full-text search.
public struct TextSearchOptions: Equatable, Sendable {
    /// Match case exactly. Off by default (case-insensitive).
    public var caseSensitive: Bool
    /// Only match whole words (word-boundary anchored).
    public var wholeWord: Bool
    /// Treat the query as an ICU regular expression rather than a literal.
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// A single search hit within a body of text.
public struct TextMatch: Equatable, Sendable {
    /// UTF-16 range of the hit in the *searched* string. This is what PDFKit's
    /// `PDFPage.selection(for:)` expects, so the app maps hits to selections
    /// without re-searching.
    public let range: NSRange
    /// A one-line, whitespace-collapsed snippet of context around the hit,
    /// suitable for a results list.
    public let preview: String
    /// UTF-16 range of the hit *within* `preview`, for emphasising the match.
    public let previewMatchRange: NSRange

    public init(range: NSRange, preview: String, previewMatchRange: NSRange) {
        self.range = range
        self.preview = preview
        self.previewMatchRange = previewMatchRange
    }
}

/// Finds occurrences of a query in plain text, with case / whole-word / regex
/// options, and builds a one-line preview for each hit.
///
/// This is the matching brain behind the search sidebar. It is UI- and
/// PDFKit-free: the app extracts each page's `string`, calls ``matches(in:query:options:)``,
/// then maps the returned UTF-16 ranges back onto `PDFSelection`s for
/// highlighting and jump-to. Keeping it here makes the tricky bits (whole-word
/// boundaries, regex validation, preview windowing) unit-testable in isolation.
public enum PlainTextSearch {

    /// Longest preview snippet, in characters, before we window around the hit.
    private static let maxPreviewLength = 120

    /// Return every match of `query` in `text`. An empty or whitespace-only
    /// query, or an invalid regex, yields no matches (never throws).
    public static func matches(in text: String, query: String, options: TextSearchOptions) -> [TextMatch] {
        let trimmedQuery = options.regex
            ? query
            : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !text.isEmpty else { return [] }
        guard let regex = makeRegex(for: trimmedQuery, options: options) else { return [] }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var results: [TextMatch] = []

        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match, match.range.length > 0 else { return } // skip zero-width
            let preview = makePreview(in: ns, matchRange: match.range)
            results.append(TextMatch(range: match.range,
                                     preview: preview.text,
                                     previewMatchRange: preview.matchRange))
        }
        return results
    }

    // MARK: - Regex construction

    private static func makeRegex(for query: String, options: TextSearchOptions) -> NSRegularExpression? {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            // Lookarounds instead of \b so a query beginning/ending with a
            // non-word character degrades to "no match" rather than misbehaving.
            pattern = "(?<!\\w)(?:\(pattern))(?!\\w)"
        }
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    // MARK: - Preview construction

    /// Build a one-line preview: take the text line containing the hit, collapse
    /// runs of whitespace to single spaces, and — if still too long — window it
    /// around the hit with leading/trailing ellipses.
    private static func makePreview(in ns: NSString, matchRange: NSRange) -> (text: String, matchRange: NSRange) {
        // Bound the preview to the line(s) the match sits on.
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: matchRange.location, length: 0))
        // Extend the line end to cover a match that spans line breaks.
        let matchEnd = matchRange.location + matchRange.length
        if matchEnd > contentsEnd {
            var s2 = 0, e2 = 0, ce2 = 0
            ns.getLineStart(&s2, end: &e2, contentsEnd: &ce2,
                            for: NSRange(location: min(matchEnd, ns.length), length: 0))
            contentsEnd = max(contentsEnd, ce2)
        }

        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let rawLine = ns.substring(with: lineRange)

        // Collapse whitespace while tracking where the match lands in the result.
        let matchStartInLine = matchRange.location - lineStart
        let matchLenInLine = min(matchRange.length, lineRange.length - matchStartInLine)
        let collapsed = collapseWhitespace(rawLine,
                                           matchStart: matchStartInLine,
                                           matchLength: max(matchLenInLine, 0))

        return windowIfNeeded(collapsed.text, matchRange: collapsed.matchRange)
    }

    /// Collapse whitespace runs to a single space, mapping the match range from
    /// the original line onto the collapsed line.
    ///
    /// Works on UTF-16 code units (matching `NSRange`) and builds an explicit
    /// old→new index map so the returned match range is exact regardless of how
    /// many spaces were squeezed out before, inside, or after the hit.
    private static func collapseWhitespace(_ line: String, matchStart: Int, matchLength: Int)
        -> (text: String, matchRange: NSRange) {
        let source = line as NSString
        var out = ""
        // indexMap[i] = index in `out` at which source unit i landed (or where it
        // would land, for a squeezed-out space). Sized length+1 so the exclusive
        // match end always has a mapping.
        var indexMap = [Int](repeating: 0, count: source.length + 1)
        var lastWasSpace = true // treat start as "after space" so leading ws is dropped

        // Classify a UTF-16 unit as whitespace. Only BMP scalars can be
        // whitespace; a surrogate half (0xD800–0xDFFF) never is, so we classify
        // it as non-space without decoding (decoding a lone half fails).
        func isWhitespaceUnit(_ c: unichar) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
                || (c < 0xD800 && (Unicode.Scalar(c).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false))
        }

        // Copy maximal *runs* of non-whitespace verbatim (so surrogate pairs stay
        // intact — appending single UTF-16 halves would corrupt them), collapsing
        // each whitespace run to a single space.
        var outLength = 0 // UTF-16 length of `out`, tracked to avoid O(n²) casts
        var i = 0
        while i < source.length {
            if isWhitespaceUnit(source.character(at: i)) {
                let start = i
                while i < source.length, isWhitespaceUnit(source.character(at: i)) {
                    i += 1
                }
                // Map every unit of this whitespace run to the collapsed space
                // position (which is `outLength` before we append the space).
                for j in start..<i { indexMap[j] = outLength }
                if !lastWasSpace { out += " "; outLength += 1; lastWasSpace = true }
            } else {
                let start = i
                while i < source.length, !isWhitespaceUnit(source.character(at: i)) {
                    indexMap[i] = outLength + (i - start)
                    i += 1
                }
                out += source.substring(with: NSRange(location: start, length: i - start))
                outLength += (i - start)
                lastWasSpace = false
            }
        }
        indexMap[source.length] = outLength

        // Map the match endpoints, then trim a trailing collapsed space.
        var trimmed = out
        if trimmed.hasSuffix(" ") { trimmed.removeLast() }
        let trimmedLen = (trimmed as NSString).length

        let mappedStart = min(indexMap[min(matchStart, source.length)], trimmedLen)
        let mappedEnd = min(indexMap[min(matchStart + matchLength, source.length)], trimmedLen)
        return (trimmed, NSRange(location: mappedStart, length: max(mappedEnd - mappedStart, 0)))
    }

    /// If the preview line is longer than `maxPreviewLength`, window it around
    /// the match with ellipses so the hit stays visible.
    ///
    /// Index math is kept exact by only ever *moving the window start* (never
    /// trimming its front), so the match offset within the window is simply
    /// `matchLocation - windowStart` plus any prefix ellipsis length.
    private static func windowIfNeeded(_ text: String, matchRange: NSRange) -> (text: String, matchRange: NSRange) {
        let ns = text as NSString
        guard ns.length > maxPreviewLength else { return (text, matchRange) }

        let space: unichar = 0x20
        let matchEnd = matchRange.location + matchRange.length
        let margin = max((maxPreviewLength - matchRange.length) / 2, 8)

        var start = max(0, matchRange.location - margin)
        var end = min(ns.length, matchEnd + margin)

        // Snap the start forward to a word boundary (just after a space), never
        // past the match. Snap the end backward likewise, never before the match.
        if start > 0 {
            while start < matchRange.location && ns.character(at: start - 1) != space { start += 1 }
        }
        if end < ns.length {
            while end > matchEnd && ns.character(at: end - 1) != space { end -= 1 }
        }

        var windowed = ns.substring(with: NSRange(location: start, length: end - start))
        var newMatchStart = matchRange.location - start

        if start > 0 {
            let prefix = "… "
            windowed = prefix + windowed
            newMatchStart += (prefix as NSString).length
        }
        // A trailing collapsed space is cosmetic and doesn't affect the match
        // offset; drop it before appending the ellipsis.
        if end < ns.length {
            while windowed.hasSuffix(" ") { windowed.removeLast() }
            windowed += " …"
        }

        let windowedNS = windowed as NSString
        newMatchStart = max(0, min(newMatchStart, windowedNS.length))
        let newLen = min(matchRange.length, windowedNS.length - newMatchStart)
        return (windowed, NSRange(location: newMatchStart, length: max(newLen, 0)))
    }
}
