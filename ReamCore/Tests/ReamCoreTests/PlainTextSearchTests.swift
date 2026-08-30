import XCTest
@testable import ReamCore

/// Tests for full-text search matching, previews, and the case/whole-word/regex
/// toggles — the indexing behind the search sidebar.
final class PlainTextSearchTests: XCTestCase {

    private let body = "The quick brown fox jumps over the lazy dog. The dog slept."

    func testFindsAllCaseInsensitiveMatches() {
        let hits = PlainTextSearch.matches(in: body, query: "the", options: .init())
        // "The", "the", "The" → 3 (case-insensitive default).
        XCTAssertEqual(hits.count, 3)
    }

    func testCaseSensitiveNarrowsMatches() {
        let hits = PlainTextSearch.matches(in: body, query: "The",
                                           options: .init(caseSensitive: true))
        // Only the two capital-T "The"s.
        XCTAssertEqual(hits.count, 2)
    }

    func testWholeWordExcludesSubstrings() {
        let text = "dog doghouse hotdog dog."
        let partial = PlainTextSearch.matches(in: text, query: "dog", options: .init())
        XCTAssertEqual(partial.count, 4) // dog, dog(house), (hot)dog, dog

        let whole = PlainTextSearch.matches(in: text, query: "dog",
                                            options: .init(wholeWord: true))
        XCTAssertEqual(whole.count, 2) // only the standalone "dog" tokens
    }

    func testRangesPointAtActualText() {
        let hits = PlainTextSearch.matches(in: body, query: "fox", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        let ns = body as NSString
        XCTAssertEqual(ns.substring(with: hit.range), "fox")
    }

    func testRegexMatches() {
        let text = "Call 555-1234 or 555-9876 today."
        let hits = PlainTextSearch.matches(in: text, query: #"\d{3}-\d{4}"#,
                                           options: .init(regex: true))
        XCTAssertEqual(hits.count, 2)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: hits[0].range), "555-1234")
    }

    func testInvalidRegexYieldsNoMatchesInsteadOfThrowing() {
        let hits = PlainTextSearch.matches(in: body, query: "([",
                                           options: .init(regex: true))
        XCTAssertTrue(hits.isEmpty)
    }

    func testEmptyQueryYieldsNoMatches() {
        XCTAssertTrue(PlainTextSearch.matches(in: body, query: "   ", options: .init()).isEmpty)
    }

    func testPreviewHighlightRangeIsTheMatch() {
        let hits = PlainTextSearch.matches(in: body, query: "lazy", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        let previewNS = hit.preview as NSString
        XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange), "lazy")
    }

    func testPreviewCollapsesWhitespace() {
        let text = "alpha      needle\t\tbravo"
        let hits = PlainTextSearch.matches(in: text, query: "needle", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        XCTAssertEqual(hit.preview, "alpha needle bravo")
        let previewNS = hit.preview as NSString
        XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange), "needle")
    }

    func testPreviewWindowsLongLinesAroundMatch() {
        let filler = String(repeating: "word ", count: 60) // ~300 chars
        let text = filler + "NEEDLE " + filler
        let hits = PlainTextSearch.matches(in: text, query: "NEEDLE", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        XCTAssertLessThan((hit.preview as NSString).length, 200)
        XCTAssertTrue(hit.preview.contains("NEEDLE"))
        XCTAssertTrue(hit.preview.contains("…"))
        let previewNS = hit.preview as NSString
        XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange), "NEEDLE")
    }

    func testMultipleMatchesOnOneLineEachGetPreview() {
        let text = "cat dog cat"
        let hits = PlainTextSearch.matches(in: text, query: "cat", options: .init())
        XCTAssertEqual(hits.count, 2)
        for hit in hits {
            let previewNS = hit.preview as NSString
            XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange).lowercased(), "cat")
        }
    }

    /// A non-BMP character (emoji) on the match line must survive intact in the
    /// preview — not be turned into replacement spaces by UTF-16 surrogate
    /// mishandling.
    func testPreviewPreservesNonBMPCharacters() {
        let text = "alpha 😀 needle bravo"
        let hits = PlainTextSearch.matches(in: text, query: "needle", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        XCTAssertTrue(hit.preview.contains("😀"), "emoji should be preserved in preview")
        XCTAssertEqual(hit.preview, "alpha 😀 needle bravo")
        let previewNS = hit.preview as NSString
        XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange), "needle")
    }

    /// A match whose preview line contains a non-BMP char *before* the hit must
    /// still point the preview match range at the right substring.
    func testPreviewMatchRangeCorrectAfterNonBMP() {
        let text = "😀😀😀 target here"
        let hits = PlainTextSearch.matches(in: text, query: "target", options: .init())
        let hit = try! XCTUnwrap(hits.first)
        let previewNS = hit.preview as NSString
        XCTAssertEqual(previewNS.substring(with: hit.previewMatchRange), "target")
    }
}
