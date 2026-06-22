import XCTest
@testable import editxr

/// Deterministic render tests: build a document, render the content area at a
/// fixed size (no terminal), strip styling, and assert on the visible text.
/// These replace flaky PTY captures — every render/markup change should land
/// with a case here (see AGENTS.md).
final class RenderTests: XCTestCase {

    // MARK: - Helpers

    /// Strip ANSI/OSC escape sequences, leaving the visible characters.
    static func plain(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                i += 1
                // CSI: ESC [ … <final letter>
                if i < chars.count && chars[i] == "[" {
                    i += 1
                    while i < chars.count && !chars[i].isLetter { i += 1 }
                    if i < chars.count { i += 1 }
                } else {
                    // Other escapes: skip the introducer byte.
                    if i < chars.count { i += 1 }
                }
                continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// Build an EditorApp around `content`, with the cursor parked on a line
    /// other than the ones under test (so they render collapsed, not raw).
    func makeApp(_ content: String, cursorLine: Int, wordWrap: Bool = true) -> EditorApp {
        let tmp = NSTemporaryDirectory() + "editxr-test-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = wordWrap
        state.blockMode = false
        let clamped = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorLine = clamped
        state.document.cursorColumn = 0
        return EditorApp(states: [state])
    }

    /// Visible rendered rows (styling stripped, trailing spaces trimmed),
    /// dropping fully-blank rows.
    func renderedRows(_ app: EditorApp, width: Int, height: Int = 20) -> [String] {
        app.renderContentLinesForTest(width: width, height: height)
            .map { RenderTests.plain($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - The wrapped-list-with-span regression

    func testWrappedBulletWithBoldKeepsAllText() {
        // A bullet whose **bold** run is followed by more text, long enough to
        // wrap several times at a narrow width. The whole thing must survive.
        let content = """
        - bullet con **negrita larga que cruza el limite** y sigue texto normal despues del cierre para llenar varias filas
        segunda linea
        """
        let app = makeApp(content, cursorLine: 1)
        let joined = renderedRows(app, width: 30).joined(separator: " ")

        XCTAssertTrue(joined.contains("bullet con"), "lost the text before the bold run:\n\(joined)")
        XCTAssertTrue(joined.contains("negrita"), "lost the start of the bold run:\n\(joined)")
        XCTAssertTrue(joined.contains("limite"), "lost the end of the bold run:\n\(joined)")
        XCTAssertTrue(joined.contains("sigue texto normal"), "lost the text after the bold run:\n\(joined)")
    }

    func testWrappedRowsNeverExceedWidth() {
        // ASCII content: every wrapped row must fit the gutter + content budget.
        let content = """
        - bullet con **negrita larga que cruza el limite** y sigue texto normal despues del cierre para llenar varias filas
        segunda linea
        """
        assertRowsWithinBudget(content, width: 30)
    }

    /// Wide glyphs (emoji, CJK) occupy two columns but one Character. wrapLine
    /// must break on display width, not Character count, or rows overflow the
    /// terminal and the layout below them shifts ("rompe el renderizado").
    func testWrappedRowsWithEmojiNeverExceedWidth() {
        let content = """
        - uno 🎭 dos 🎬 tres 🛡 cuatro ⚖ cinco 🎭 seis 🎬 siete 🛡 ocho ⚖ nueve diez once doce
        segunda linea
        """
        assertRowsWithinBudget(content, width: 30)
    }

    func testWideCJKRowsNeverExceedWidth() {
        let content = """
        - 你好世界 这是 一个 很长 的 列表 项目 用来 测试 自动 换行 是否 正确 处理 全角 字符 的 宽度 计算 问题
        segunda linea
        """
        assertRowsWithinBudget(content, width: 24)
    }

    /// Render every row and assert no row is wider on screen than the others.
    /// Rows are padded to a fixed `gutter + width` budget, so the narrowest row
    /// reveals the true budget; any row exceeding it overflows the terminal.
    private func assertRowsWithinBudget(_ content: String, width: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let app = makeApp(content, cursorLine: 1)
        let rows = app.renderContentLinesForTest(width: width, height: 24)
        let widths = rows.map { RenderTests.plain($0).displayWidth }
        guard let budget = widths.min() else { return }
        for (i, dw) in widths.enumerated() {
            XCTAssertLessThanOrEqual(dw, budget,
                "row display-width \(dw) exceeds budget \(budget): '\(RenderTests.plain(rows[i]))'",
                file: file, line: line)
        }
    }
}
