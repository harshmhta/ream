import XCTest
@testable import ReamCore

/// Tests for smart de-hyphenation and paragraph joining — the logic behind
/// "copy without line-break garbage".
final class TextReflowTests: XCTestCase {

    func testJoinsLineBreakHyphenatedWord() {
        // Justification split: lowercase both sides → drop hyphen, rejoin.
        let input = "This is a demonstra-\ntion of de-hyphenation."
        XCTAssertEqual(TextReflow.dehyphenate(input),
                       "This is a demonstration of de-hyphenation.")
    }

    func testKeepsMeaningfulHyphenBeforeUppercase() {
        // "MS-DOS" wrapping at the hyphen: uppercase after → keep the hyphen.
        let input = "run it on MS-\nDOS today"
        XCTAssertEqual(TextReflow.dehyphenate(input), "run it on MS-DOS today")
    }

    func testKeepsHyphenAroundDigits() {
        // Number range wrapping: keep the hyphen.
        let input = "fiscal year 2019-\n2020 report"
        XCTAssertEqual(TextReflow.dehyphenate(input), "fiscal year 2019-2020 report")
    }

    func testDropsSoftHyphenAtLineBreak() {
        let input = "opti\u{00AD}\nmize"
        XCTAssertEqual(TextReflow.dehyphenate(input), "optimize")
    }

    func testJoinsPlainLinesWithSpace() {
        let input = "The quick brown\nfox jumps over\nthe lazy dog"
        XCTAssertEqual(TextReflow.dehyphenate(input),
                       "The quick brown fox jumps over the lazy dog")
    }

    func testPreservesParagraphBoundaries() {
        let input = "First para line one\nline two.\n\nSecond para here."
        XCTAssertEqual(TextReflow.dehyphenate(input),
                       "First para line one line two.\n\nSecond para here.")
    }

    func testCollapsesMultipleBlankLinesToSingleBreak() {
        let input = "Alpha\n\n\n\nBravo"
        XCTAssertEqual(TextReflow.dehyphenate(input), "Alpha\n\nBravo")
    }

    func testNormalizesCRLF() {
        let input = "one two\r\nthree four"
        XCTAssertEqual(TextReflow.dehyphenate(input), "one two three four")
    }

    func testDashSurroundedBySpacesIsNotDehyphenated() {
        // An em-dash-style " - " at a line end is not a word split.
        let input = "a list item -\nand another"
        XCTAssertEqual(TextReflow.dehyphenate(input), "a list item - and another")
    }

    func testEmptyStringYieldsEmpty() {
        XCTAssertEqual(TextReflow.dehyphenate(""), "")
    }

    func testHandlesUnicodeHyphenScalar() {
        // U+2010 HYPHEN, lowercase both sides → join.
        let input = "water\u{2010}\nfall"
        XCTAssertEqual(TextReflow.dehyphenate(input), "waterfall")
    }

    func testTrimsIntralineWhitespaceWhenJoining() {
        let input = "leading   \n   trailing"
        XCTAssertEqual(TextReflow.dehyphenate(input), "leading trailing")
    }
}
