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
                } else if i < chars.count && chars[i] == "]" {
                    // OSC (e.g. OSC 8 hyperlinks): ESC ] … terminated by BEL or
                    // ST (ESC \). Skip the whole sequence, URI payload included.
                    i += 1
                    while i < chars.count {
                        if chars[i] == "\u{07}" { i += 1; break }
                        if chars[i] == "\u{1B}" && i + 1 < chars.count && chars[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
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
    func makeApp(_ content: String, cursorLine: Int, wordWrap: Bool = true,
                 alignTables: Bool = false) -> EditorApp {
        let tmp = NSTemporaryDirectory() + "editxr-test-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = wordWrap
        state.blockMode = false
        state.alignTables = alignTables
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

    // MARK: - Links: collapsed display + OSC 8 hyperlinks

    func testInlineLinkRendersCollapsedAsHyperlink() {
        // The display text shows (markers + URL hidden), and the link is wrapped
        // in an OSC 8 hyperlink so the terminal underlines it on Cmd-hover and
        // follows it on Cmd-click — the affordance Claude Code's links use.
        let content = """
        Ver el [sitio oficial](https://example.com) para mas info
        segunda linea
        """
        let app = makeApp(content, cursorLine: 1)
        let raw = app.renderContentLinesForTest(width: 80, height: 20).joined()
        let visible = RenderTests.plain(raw)

        XCTAssertTrue(visible.contains("sitio oficial"), "lost the link display text:\n\(visible)")
        XCTAssertFalse(visible.contains("https://example.com"), "URL should be hidden:\n\(visible)")
        XCTAssertFalse(visible.contains("]("), "inline-link markers should be hidden:\n\(visible)")
        XCTAssertTrue(raw.contains("\u{1B}]8;;https://example.com\u{1B}\\"),
                      "missing OSC 8 hyperlink around the link text")
    }

    func testWikilinkRendersAliasCollapsed() {
        // [[Target|alias]] collapses to the alias; brackets, pipe, and the
        // target name are all hidden.
        let content = """
        Mira la [[Otra Nota|nota relacionada]] aca
        segunda linea
        """
        let app = makeApp(content, cursorLine: 1)
        let visible = renderedRows(app, width: 80).joined(separator: " ")

        XCTAssertTrue(visible.contains("nota relacionada"), "lost the wikilink alias:\n\(visible)")
        XCTAssertFalse(visible.contains("[["), "wikilink markers should be hidden:\n\(visible)")
        XCTAssertFalse(visible.contains("Otra Nota"), "wikilink target name should not show:\n\(visible)")
    }

    /// Render every row and assert no row is wider on screen than the others.
    // MARK: - Table alignment with status symbols

    /// A table whose columns mix ambiguous-width symbols (★ ✓ ⚠) with real
    /// emoji (✅ ⛔) and plain text. Every rendered table row must share one
    /// display width, or the box goes ragged (the reported bug: ★/✓ counted as
    /// two columns shifted each row a column to the left).
    func testTableWithStatusSymbolsStaysAligned() {
        let content = """
        # Heading

        | Situation | Demand | Corpus | Note |
        |---|:--:|:--:|---|
        | General anxiety | ★ | ✅ 228 | Build hub now |
        | Panic attack | ★ | ⛔ | Top priority |
        | Health anxiety | ✓ | ⛔ | Generate |
        | Fear / letting go | ✓ | ⚠️ | Partial via anxiety |
        | Loss of a pet | — | ⛔ | Generate |
        """
        // Cursor on the heading so the whole table renders collapsed (boxed).
        let app = makeApp(content, cursorLine: 0)
        let rows = app.renderContentLinesForTest(width: 80, height: 24)
            .map { RenderTests.plain($0) }
            .filter { $0.contains("│") || $0.contains("├") || $0.contains("╭") || $0.contains("╰") }

        XCTAssertGreaterThanOrEqual(rows.count, 6, "expected the full boxed table")
        // Rows are padded to the terminal width; trim to the real box width (each
        // row ends at its border) so a ragged column actually shows up here.
        func boxWidth(_ s: String) -> Int {
            var t = s; while t.hasSuffix(" ") { t.removeLast() }; return t.displayWidth
        }
        let widths = Set(rows.map(boxWidth))
        XCTAssertEqual(widths.count, 1,
            "table rows have mismatched widths \(widths.sorted()):\n" + rows.joined(separator: "\n"))
    }

    /// Box widths of every boxed table row. Rows are padded to the full terminal
    /// width, so trailing spaces are trimmed to recover each table's true width
    /// (a table row ends at its right border, never a space).
    private func tableRowWidths(_ content: String, alignTables: Bool) -> Set<Int> {
        let app = makeApp(content, cursorLine: 0, alignTables: alignTables)
        let rows = app.renderContentLinesForTest(width: 120, height: 30)
            .map { RenderTests.plain($0) }
            .filter { r in r.contains("│") || r.contains("├") || r.contains("╭") || r.contains("╰") }
        func boxWidth(_ s: String) -> Int {
            var t = s
            while t.hasSuffix(" ") { t.removeLast() }
            return t.displayWidth
        }
        return Set(rows.map(boxWidth))
    }

    private let twoUnevenTables = """
    # Doc

    | A | B |
    |---|---|
    | x | y |

    | Much wider heading here | C |
    |---|---|
    | value | z |
    """

    func testAlignTablesMakesEveryTableTheSameWidth() {
        let widths = tableRowWidths(twoUnevenTables, alignTables: true)
        XCTAssertEqual(widths.count, 1,
            "aligned tables should share one width, got \(widths.sorted())")
    }

    func testTablesKeepNaturalWidthsWhenAlignmentOff() {
        // Control: with the preference off the two tables differ in width.
        let widths = tableRowWidths(twoUnevenTables, alignTables: false)
        XCTAssertGreaterThan(widths.count, 1,
            "unaligned tables of different widths should not all match")
    }

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
