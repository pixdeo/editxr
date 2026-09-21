import XCTest
@testable import editxr

/// Tabs are stored raw (native, `md`-friendly) but measured at the configured
/// tab stop so wrapping and the caret agree with what the terminal shows. These
/// pin the width math, the display-only expansion, and that a raw tab never
/// reaches the output (its column would depend on the terminal's own stops).
final class TabLayoutTests: XCTestCase {

    private func makeApp(_ content: String, cursorLine: Int = 0) -> (EditorApp, EditorState) {
        let tmp = NSTemporaryDirectory() + "editxr-tab-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.showLineNumbers = false
        state.leftMargin = 0
        state.tabWidth = 8
        let clamped = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorLine = clamped
        state.document.cursorColumn = 0
        return (EditorApp(states: [state]), state)
    }

    // MARK: - Width math

    func testTabAdvanceSnapsToTheNextStop() {
        XCTAssertEqual(displayAdvance("\t", atColumn: 0, tabStop: 8), 8)
        XCTAssertEqual(displayAdvance("\t", atColumn: 5, tabStop: 8), 3)
        XCTAssertEqual(displayAdvance("\t", atColumn: 8, tabStop: 8), 8)
        XCTAssertEqual(displayAdvance("\t", atColumn: 1, tabStop: 4), 3)
        XCTAssertEqual(displayAdvance("a", atColumn: 0, tabStop: 8), 1)
    }

    func testExpandTabsHonoursTheConfiguredWidth() {
        XCTAssertEqual(expandTabs("a\tb", originColumn: 0, tabStop: 8), "a       b")
        XCTAssertEqual(expandTabs("a\tb", originColumn: 0, tabStop: 4), "a   b")
    }

    func testWrapMeasuresATabByItsExpandedWidth() {
        let rows = wrapTextRows("\tabc", width: 8, tabStop: 8).map { $0.segment }
        XCTAssertEqual(rows, ["\t", "abc"])
        XCTAssertEqual(expandedDisplayWidth("\t", tabStop: 8), 8)
    }

    // MARK: - Rendered frame

    func testRenderedRowsNeverCarryRawTabsAndFitTheBudget() {
        let line = String(repeating: "a\tbb\tccc\t", count: 20)
        let (app, _) = makeApp(line + "\nsegunda")
        let rows = app.renderContentLinesForTest(width: 30, height: 24)
        let widths = rows.map { RenderTests.plain($0).displayWidth }
        guard let budget = widths.min() else { return XCTFail("no rows rendered") }
        for (i, row) in rows.enumerated() {
            XCTAssertFalse(row.contains("\t"), "raw tab leaked into row \(i)")
            XCTAssertLessThanOrEqual(widths[i], budget,
                "row \(i) overflows: \(RenderTests.plain(row).debugDescription)")
        }
    }

    func testTabbedCodeBlockRowsFitTheBudget() {
        let content = "```\n\tfunc x() {\n\t\tlet a = 1\n\t}\n```\n"
        let (app, _) = makeApp(content, cursorLine: 4)
        let rows = app.renderContentLinesForTest(width: 30, height: 20)
        let widths = rows.map { RenderTests.plain($0).displayWidth }
        guard let budget = widths.min() else { return XCTFail("no rows rendered") }
        for (i, row) in rows.enumerated() {
            XCTAssertFalse(row.contains("\t"), "raw tab leaked into code-block row \(i)")
            XCTAssertLessThanOrEqual(widths[i], budget,
                "code-block row \(i) overflows: \(RenderTests.plain(row).debugDescription)")
        }
    }

    func testCaretVisibleOnAndAfterTabbedLines() {
        let content = "a\tbb\tccc\tdddd\n" + String(repeating: "x\t", count: 40) + "end"
        let (app, state) = makeApp(content, cursorLine: 0)

        state.document.cursorColumn = state.document.lines[0].count
        var frame = app.renderEditorLinesForTest(width: 40, height: 20).joined(separator: "\n")
        XCTAssertTrue(frame.contains(Theme.inverse), "caret missing at the end of a tabbed line")

        state.document.cursorLine = 1
        state.document.cursorColumn = state.document.lines[1].count
        frame = app.renderEditorLinesForTest(width: 40, height: 20).joined(separator: "\n")
        XCTAssertTrue(frame.contains(Theme.inverse), "caret missing after a long tabbed line")
    }
}
