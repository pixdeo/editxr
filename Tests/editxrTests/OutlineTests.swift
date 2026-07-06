import XCTest
@testable import editxr

final class OutlineTests: XCTestCase {

    private func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    func testExtractsHeadingsWithLevelAndLine() {
        let items = Outline.items(from: lines("""
        # Title
        intro text
        ## Section A
        body
        ### Detail
        #### Deep
        ## Section B
        """))
        XCTAssertEqual(items, [
            OutlineItem(level: 1, title: "Title", line: 0),
            OutlineItem(level: 2, title: "Section A", line: 2),
            OutlineItem(level: 3, title: "Detail", line: 4),
            OutlineItem(level: 4, title: "Deep", line: 5),
            OutlineItem(level: 2, title: "Section B", line: 6),
        ])
    }

    func testSkipsHeadingsInsideCodeFences() {
        let items = Outline.items(from: lines("""
        # Real
        ```
        # not a heading (shell comment)
        ## also code
        ```
        ## Also real
        """))
        XCTAssertEqual(items.map(\.title), ["Real", "Also real"])
    }

    func testIgnoresNonHeadings() {
        let items = Outline.items(from: lines("""
        #nospace
        ####### sevenhashes
        #
        plain line
        ## Valid
        """))
        XCTAssertEqual(items, [OutlineItem(level: 2, title: "Valid", line: 4)])
    }

    func testKeepsInlineMarkupInTitle() {
        // Outline stores the raw title; the panel label strips emphasis markers.
        let items = Outline.items(from: lines("## El **engine** de `custom`"))
        XCTAssertEqual(items.first?.title, "El **engine** de `custom`")
    }

    func testEmptyDocumentHasNoOutline() {
        XCTAssertTrue(Outline.items(from: [""]).isEmpty)
    }

    // MARK: - Jump navigation

    func testGoToLineRevealsTargetWithScroll() {
        let path = NSTemporaryDirectory() + "editxr-outline-\(UUID().uuidString).md"
        let body = (0..<60).map { "line \($0)" }.joined(separator: "\n")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: path)

        state.goToLine(40, viewportHeight: 24)
        XCTAssertEqual(state.document.cursorLine, 40)
        XCTAssertEqual(state.document.cursorColumn, 0)
        // Revealed a third of the way down: target - viewport/3 = 40 - 8 = 32.
        XCTAssertEqual(state.scrollOffset, 32)
    }

    func testGoToLineClampsBeyondEnd() {
        let path = NSTemporaryDirectory() + "editxr-outline-\(UUID().uuidString).md"
        try? "a\nb\nc".write(toFile: path, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: path)
        state.goToLine(999, viewportHeight: 24)
        XCTAssertLessThanOrEqual(state.document.cursorLine, state.document.lines.count - 1)
    }

    // MARK: - OutlineSidebar (pure layout)

    private let sample = [
        OutlineItem(level: 1, title: "Title", line: 0),
        OutlineItem(level: 2, title: "Section A", line: 5),
        OutlineItem(level: 3, title: "Detail", line: 8),
        OutlineItem(level: 2, title: "Section B", line: 12),
    ]

    func testSidebarIndentsByLevelAndPadsToHeight() {
        let rows = OutlineSidebar.rows(items: sample, cursorLine: 0, width: 20, height: 6)
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0].text, "Title")
        XCTAssertEqual(rows[1].text, "  Section A")
        XCTAssertEqual(rows[2].text, "    Detail")
        XCTAssertEqual(rows[4].text, "")           // padded
    }

    func testSidebarMarksCurrentSection() {
        // Cursor on line 9 → inside "Detail" (line 8, before "Section B" at 12).
        let rows = OutlineSidebar.rows(items: sample, cursorLine: 9, width: 20, height: 6)
        let current = rows.filter { $0.isCurrent }
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current.first?.text, "    Detail")
    }

    func testSidebarTruncatesWideTitles() {
        let items = [OutlineItem(level: 1, title: "A very long heading that overflows", line: 0)]
        let rows = OutlineSidebar.rows(items: items, cursorLine: 0, width: 10, height: 2)
        XCTAssertLessThanOrEqual(rows[0].text.displayWidth, 10)
        XCTAssertTrue(rows[0].text.hasSuffix("…"))
    }

    func testSidebarScrollsToKeepCurrentVisible() {
        let many = (0..<30).map { OutlineItem(level: 1, title: "H\($0)", line: $0) }
        let rows = OutlineSidebar.rows(items: many, cursorLine: 25, width: 20, height: 6)
        XCTAssertTrue(rows.contains { $0.isCurrent && $0.text == "H25" }, "current must stay visible")
    }

    func testSidebarEmptyShowsPlaceholder() {
        let rows = OutlineSidebar.rows(items: [], cursorLine: 0, width: 20, height: 4)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].text, "No headings")
    }

    // MARK: - Docked rendering (full frame composition)

    // A heading title next to the "│" separator only happens on a sidebar row:
    // status-bar chrome has "│" but no heading text; content rows have the
    // heading but no "│".
    private func makeDockedApp(_ content: String, mode: SidebarMode) -> EditorApp {
        let path = NSTemporaryDirectory() + "editxr-dock-\(UUID().uuidString).md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: path)
        state.sidebarMode = mode
        state.blockMode = false
        state.document.cursorLine = 0
        return EditorApp(states: [state])
    }

    func testOutlineSidebarDocksAndNeverOverflows() {
        let content = "# Doc\n\nbody text here in the editor\n\n## Zebra Section\n\nmore body\n"
        let app = makeDockedApp(content, mode: .outline)
        let width = 80
        let rows = app.renderEditorLinesForTest(width: width, height: 24).map { RenderTests.plain($0) }

        XCTAssertTrue(rows.contains { $0.contains("Zebra Section") && $0.contains("│") },
                      "expected a docked outline row with the separator")
        XCTAssertTrue(rows.contains { $0.contains("body text here") },
                      "editor body should still render to the right")
        for r in rows where !r.isEmpty {
            XCTAssertLessThanOrEqual(r.displayWidth, width, "row overflows: '\(r)'")
        }
    }

    func testOutlineSidebarHiddenWhenDisabled() {
        let content = "# Doc\n\nbody\n\n## Zebra Section\n"
        let app = makeDockedApp(content, mode: .off)
        let rows = app.renderEditorLinesForTest(width: 80, height: 24).map { RenderTests.plain($0) }
        XCTAssertFalse(rows.contains { $0.contains("Zebra Section") && $0.contains("│") },
                       "no docked outline column when the sidebar is off")
    }
}
