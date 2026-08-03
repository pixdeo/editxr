import XCTest
@testable import editxr

/// Escape-sequence accounting. The bug this guards: parsers that ended an
/// escape at the first letter cut OSC 8 hyperlinks (`ESC ] 8 ; ; https://…`)
/// at the `h` of `http`, counting the URI as visible text. Any line holding a
/// Markdown link then reported a huge width, so the command panel spliced over
/// it landed inside a later escape and leaked `0m` fragments onto the screen.
final class ANSIScannerTests: XCTestCase {

    private let link = Theme.hyperlinkOpen("https://sensortower.com/blog/state-of-aso")

    func testHyperlinkSequenceTakesNoColumns() {
        XCTAssertEqual(link.displayWidth, 0)
        XCTAssertEqual(Theme.hyperlinkClose.displayWidth, 0)
    }

    func testLinkedTextMeasuresOnlyItsLabel() {
        let styled = "• " + link + "AppMagic" + Theme.hyperlinkClose
        XCTAssertEqual(styled.displayWidth, 10)
    }

    func testBelTerminatedOSCTakesNoColumns() {
        XCTAssertEqual("\u{1B}]11;rgb:ff/ee/dd\u{07}".displayWidth, 0)
    }

    func testSGRAndCharsetEscapesStillSkipped() {
        XCTAssertEqual("\u{1B}[38;2;10;20;30mabc\u{1B}[0m".displayWidth, 3)
        XCTAssertEqual("\u{1B}(Babc".displayWidth, 3)
    }

    func testEscapeEndCoversWholeSequence() {
        let chars = Array(link + "x")
        XCTAssertEqual(ansiEscapeEnd(chars, from: 0), chars.count - 1)
    }

    func testEscapeEndOnSGR() {
        let chars = Array("\u{1B}[0mx")
        XCTAssertEqual(ansiEscapeEnd(chars, from: 0), 4)
    }
}
