import XCTest
@testable import editxr

/// Tab is a real editing key now: it indents (or inserts a native tab) and
/// Shift+Tab outdents, while headings keep the promote/demote pair. Task
/// cycling stays on Ctrl+T and the sidebar is focused with Alt+S, so a bare Tab
/// never disappears into a mode switch.
final class TabKeyTests: XCTestCase {

    private func makeApp(_ content: String, cursorLine: Int = 0,
                         cursorColumn: Int = 0) -> (EditorApp, EditorState) {
        let tmp = NSTemporaryDirectory() + "editxr-tabkey-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.showLineNumbers = false
        state.leftMargin = 0
        state.tabWidth = 8
        let line = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorLine = line
        state.document.cursorColumn = min(cursorColumn, state.document.lines[line].count)
        return (EditorApp(states: [state]), state)
    }

    private let shiftTab = "\u{1B}[Z"

    func testTabInsertsANativeTabOnAPlainLine() {
        let (app, state) = makeApp("hello\nworld")
        app.handleInputForTest("\t")
        XCTAssertEqual(state.document.lines[0], "\thello")
        XCTAssertEqual(state.document.cursorColumn, 1)
    }

    func testTabKeepsItsTaskMarkerUntouched() {
        // Tab must not cycle the task any more (Ctrl+T does) — it indents.
        let (app, state) = makeApp("- [ ] task\nline")
        app.handleInputForTest("\t")
        XCTAssertEqual(state.document.lines[0], "\t- [ ] task")
    }

    func testTabPromotesAHeading() {
        let (app, state) = makeApp("## Title\nbody")
        app.handleInputForTest("\t")
        XCTAssertEqual(state.document.lines[0], "# Title")
    }

    func testShiftTabOutdentsTheCursorLine() {
        let (app, state) = makeApp("\thello\nworld", cursorColumn: 1)
        app.handleInputForTest(shiftTab)
        XCTAssertEqual(state.document.lines[0], "hello")
        XCTAssertEqual(state.document.cursorColumn, 0)
    }

    func testShiftTabRemovesUpToTheTabWidthInSpaces() {
        let (app, state) = makeApp("    hello\nworld", cursorColumn: 6)
        state.tabWidth = 4
        app.handleInputForTest(shiftTab)
        XCTAssertEqual(state.document.lines[0], "hello")
    }

    func testShiftTabIsANoOpWithoutIndentation() {
        let (app, state) = makeApp("hello\nworld")
        app.handleInputForTest(shiftTab)
        XCTAssertEqual(state.document.lines[0], "hello")
        XCTAssertFalse(state.isDirty, "a no-op outdent must not dirty the buffer")
    }

    func testTabIndentsEverySelectedLine() {
        let (app, state) = makeApp("a\nb\nc")
        state.document.selectionAnchor = CursorPosition(line: 0, column: 0)
        state.document.cursorLine = 1
        state.document.cursorColumn = 1

        app.handleInputForTest("\t")

        XCTAssertEqual(state.document.lines[0], "\ta")
        XCTAssertEqual(state.document.lines[1], "\tb")
        XCTAssertEqual(state.document.lines[2], "c")
    }

    func testShiftTabOutdentsEverySelectedLine() {
        let (app, state) = makeApp("\ta\n\tb\nc")
        state.document.selectionAnchor = CursorPosition(line: 0, column: 1)
        state.document.cursorLine = 1
        state.document.cursorColumn = 2

        app.handleInputForTest(shiftTab)

        XCTAssertEqual(state.document.lines[0], "a")
        XCTAssertEqual(state.document.lines[1], "b")
        XCTAssertEqual(state.document.lines[2], "c")
    }

    func testAltSFocusesTheSidebar() {
        let (app, state) = makeApp("hello\nworld")
        state.sidebarMode = .outline
        _ = app.renderEditorLinesForTest(width: 100, height: 24)   // sets sidebarRendered
        XCTAssertTrue(app.sidebarFocusedForTest == false)

        app.handleInputForTest("\u{1B}s")

        XCTAssertTrue(app.sidebarFocusedForTest, "Alt+S should hand focus to the sidebar")
    }
}
