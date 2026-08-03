import XCTest
@testable import editxr

/// Marking the matched words in a search result: which words count, and what
/// happens to text that is already styled.
final class TextMatchTests: XCTestCase {

    private let style = "<HL>"
    private let base = "<BASE>"

    private func mark(_ text: String, _ matches: [TextMatch]) -> String {
        MatchHighlighter.mark(text, matches: matches, base: base, style: style)
    }

    /// The visible characters of a marked string, i.e. what the terminal shows.
    private func visible(_ styled: String) -> String {
        var scanner = ANSIScanner()
        return String(styled.filter { !scanner.consume($0) })
            .replacingOccurrences(of: style, with: "")
            .replacingOccurrences(of: base, with: "")
    }

    func testAWholeWordIsMarkedAndTheRestIsUntouched() {
        let out = mark("Deploy the rollback", [TextMatch(text: "rollback", isPrefix: false)])
        XCTAssertTrue(out.contains("\(style)rollback"))
        XCTAssertFalse(out.contains("\(style)Deploy"))
    }

    func testMarkingChangesNothingVisible() {
        // Columns are computed from the unmarked text, so the marks must not add
        // or drop a single visible character.
        let text = "Cáncer de Rubén › control"
        let out = mark(text, [TextMatch(text: "ruben", isPrefix: false)])
        XCTAssertEqual(visible(out), text)
    }

    func testAnAccentedWordIsMarkedByItsFoldedForm() {
        // The query is "ruben"; what is on screen is "Rubén".
        let out = mark("Cáncer de Rubén", [TextMatch(text: "ruben", isPrefix: false)])
        XCTAssertTrue(out.contains("\(style)Rubén"))
    }

    func testCaseDoesNotMatter() {
        let out = mark("Transformer notes", [TextMatch(text: "transformer", isPrefix: false)])
        XCTAssertTrue(out.contains("\(style)Transformer"))
    }

    func testAPrefixMatchMarksTheWholeWord() {
        // Mid-typing, the word on screen is longer than what was typed; marking
        // half a word reads as a rendering fault.
        let out = mark("rollback plan", [TextMatch(text: "roll", isPrefix: true)])
        XCTAssertTrue(out.contains("\(style)rollback"))
    }

    func testAFinishedWordDoesNotMarkLongerWords() {
        let out = mark("rollback plan", [TextMatch(text: "roll", isPrefix: false)])
        XCTAssertFalse(out.contains(style))
    }

    func testEveryOccurrenceIsMarked() {
        let out = mark("deploy then deploy again", [TextMatch(text: "deploy", isPrefix: false)])
        XCTAssertEqual(out.components(separatedBy: "\(style)deploy").count - 1, 2)
    }

    func testStyledTextKeepsItsStylingAroundAMark() {
        // The mark interrupts the note's own styling, so what was in force has
        // to be put back — otherwise the rest of the line takes the mark's
        // colours and the pane looks like one long highlight.
        let bold = "\u{1B}[1m"
        let reset = "\u{1B}[0m"
        let out = mark("\(bold)deploy the rollback\(reset)",
                       [TextMatch(text: "deploy", isPrefix: false)])
        XCTAssertTrue(out.contains("\(style)deploy"))
        XCTAssertTrue(out.contains("\(base)\(bold)"), "the interrupted styling was not restored")
        XCTAssertEqual(visible(out), "deploy the rollback")
    }

    func testAMarkNeverLandsInsideAnEscapeSequence() {
        // A hyperlink is emitted as an OSC string holding a URI; marking a word
        // inside that payload would corrupt the sequence.
        let link = "\u{1B}]8;;https://deploy.example.com\u{1B}\\text\u{1B}]8;;\u{1B}\\"
        let out = mark(link, [TextMatch(text: "deploy", isPrefix: false)])
        XCTAssertFalse(out.contains("\(style)deploy"))
        XCTAssertEqual(visible(out), "text")
    }

    func testNoMatchesLeavesTheStringIdentical() {
        XCTAssertEqual(mark("nothing to do here", []), "nothing to do here")
    }

    func testPunctuationSeparatesWords() {
        let out = mark("deploy/rollback, again", [TextMatch(text: "rollback", isPrefix: false)])
        XCTAssertTrue(out.contains("\(style)rollback"))
        XCTAssertEqual(visible(out), "deploy/rollback, again")
    }
}
