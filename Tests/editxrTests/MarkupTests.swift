import XCTest
@testable import editxr

/// Markup conversions: HTML export (Ctrl-E) and inline emphasis inside headings.
final class MarkupTests: XCTestCase {

    // MARK: - Ordered lists in HTML export

    func testOrderedListBecomesOlNotOneParagraph() {
        let md = ["1. first item", "2. second item", "3. third item"]
        let html = MarkdownHTML.render(md)
        XCTAssertTrue(html.contains("<ol>"), "ordered list should produce <ol>")
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 3, "one <li> per item")
        XCTAssertFalse(html.contains("1. first item"),
                       "items must not collapse into a literal paragraph")
    }

    func testOrderedListHonoursStartNumber() {
        let html = MarkdownHTML.render(["5. five", "6. six"])
        XCTAssertTrue(html.contains("<ol start=\"5\">"), "non-1 start preserved")
    }

    func testOrderedListAcceptsParenDelimiter() {
        let html = MarkdownHTML.render(["1) alpha", "2) beta"])
        XCTAssertTrue(html.contains("<ol>"))
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2)
    }

    func testBulletListStillRenders() {
        let html = MarkdownHTML.render(["- one", "- two"])
        XCTAssertTrue(html.contains("<ul"))
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2)
    }

    func testNonListNumberStaysParagraph() {
        // No space after the dot → not a list item.
        let html = MarkdownHTML.render(["3.14 is pi"])
        XCTAssertFalse(html.contains("<ol"))
        XCTAssertTrue(html.contains("<p>"))
    }

    // MARK: - Inline emphasis inside headings

    func testHeadingCollapsesInlineBoldMarkers() {
        let content = "## Titulo con **negrita** adentro\nbody line"
        let tmp = NSTemporaryDirectory() + "editxr-md-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.document.cursorLine = 1   // keep the heading off the cursor line
        let app = EditorApp(states: [state])

        let headingRow = app.renderContentLinesForTest(width: 60, height: 12)
            .map { RenderTests.plain($0) }
            .first { $0.contains("Titulo") } ?? ""

        XCTAssertTrue(headingRow.contains("Titulo con negrita adentro"),
                      "heading text should read cleanly: '\(headingRow)'")
        XCTAssertFalse(headingRow.contains("**"),
                       "the inner bold markers must be hidden: '\(headingRow)'")
        XCTAssertFalse(headingRow.contains("#"),
                       "the heading marker must be hidden: '\(headingRow)'")
    }
}
