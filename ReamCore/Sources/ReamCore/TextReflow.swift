import Foundation

/// Turns text extracted from a PDF (which arrives broken into visual lines) into
/// clean, copy-pasteable prose.
///
/// PDF has no notion of a "paragraph": a text layer is a bag of positioned
/// glyphs, so anything you copy comes out with a hard line break at every
/// visual line and — worse — words hyphenated across a line break come out with
/// the hyphen baked in ("hyphen-\nation"). ``TextReflow`` fixes both:
///
/// - **De-hyphenation.** A hyphen sitting at the end of a line, flanked by word
///   characters, is a line-break hyphen. When both sides are lowercase letters
///   the word was split for justification and we rejoin it *without* the hyphen
///   ("hyphen-\nation" → "hyphenation"). When either side is uppercase or a
///   digit the hyphen is meaningful (proper nouns, "MS-DOS", "2019-2020") so we
///   keep it and just close the break.
/// - **Paragraph joining.** Single line breaks inside a run of text become a
///   space; blank lines mark a real paragraph boundary and are preserved as a
///   single blank line.
///
/// This is deliberately UI-free and dictionary-free so it lives in ``ReamCore``
/// and is trivially testable. The one unavoidable ambiguity — a lowercase
/// compound genuinely spelled with a hyphen, e.g. "well-known", that also
/// happens to wrap at the hyphen — is resolved toward de-hyphenation, matching
/// what mainstream PDF viewers do. A future dictionary pass could refine it.
public enum TextReflow {

    /// Hyphen code points treated as candidate line-break hyphens.
    private static let hyphenScalars: Set<Character> = ["-", "\u{2010}"]

    /// Soft hyphen (U+00AD): an explicit "break here if needed" marker. When it
    /// lands at a line end it is always dropped and the word rejoined.
    private static let softHyphen: Character = "\u{00AD}"

    /// De-hyphenate and paragraph-join `text`, returning clean prose.
    public static func dehyphenate(_ text: String) -> String {
        // Normalize line endings so CRLF / CR docs behave like LF.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Group physical lines into paragraphs. A blank (whitespace-only) line
        // ends the current paragraph; runs of blank lines collapse to one break.
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
            .map(joinLines)
            .joined(separator: "\n\n")
    }

    /// Join the physical lines of a single paragraph, applying de-hyphenation.
    private static func joinLines(_ lines: [String]) -> String {
        guard let first = lines.first else { return "" }
        var result = trimTrailingWhitespace(first)

        for raw in lines.dropFirst() {
            let line = trimLeadingWhitespace(trimTrailingWhitespace(raw))
            guard !line.isEmpty else { continue }

            // Soft hyphen at the break: always rejoin without it.
            if result.last == softHyphen {
                result.removeLast()
                result += line
                continue
            }

            if let last = result.last, hyphenScalars.contains(last) {
                let beforeHyphen = result.dropLast().last
                let afterBreak = line.first
                if let b = beforeHyphen, let a = afterBreak,
                   isWordScalar(b), isWordScalar(a) {
                    if b.isLowercase && a.isLowercase {
                        // Word split across lines for justification: drop hyphen.
                        result.removeLast()
                        result += line
                    } else {
                        // Meaningful hyphen (proper noun, acronym, number range):
                        // keep it, just close the break.
                        result += line
                    }
                    continue
                }
                // Hyphen flanked by whitespace/punctuation is a real dash — fall
                // through and join with a space so it reads naturally.
            }

            result += " " + line
        }

        return result
    }

    /// A word scalar for hyphenation purposes: a letter or a digit.
    private static func isWordScalar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var s = s
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return s
    }

    private static func trimLeadingWhitespace(_ s: String) -> String {
        var s = Substring(s)
        while let first = s.first, first == " " || first == "\t" { s.removeFirst() }
        return String(s)
    }
}
