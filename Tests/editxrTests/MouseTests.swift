import XCTest
@testable import editxr

/// Mouse multi-click: double-click selects the word, triple-click the line,
/// and further clicks alternate between the two. Click counting is driven by
/// time + position proximity.
final class MouseTests: XCTestCase {

    private func makeState(_ content: String) -> EditorState {
        let path = NSTemporaryDirectory() + "editxr-mouse-\(UUID().uuidString).md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return EditorState(filePath: path)
    }

    // MARK: - Click counting

    /// Presses close in time on the same cell advance the count 1 → 2 → 3.
    func testClicksWithinIntervalAndCellAdvance() {
        let app = EditorApp(states: [makeState("hello\n")])
        let t0 = Date()
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0), 1)
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0.addingTimeInterval(0.3)), 2)
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0.addingTimeInterval(0.6)), 3)
    }

    /// A press past the click window restarts the sequence at 1.
    func testClickTooLateRestarts() {
        let app = EditorApp(states: [makeState("hello\n")])
        let t0 = Date()
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0), 1)
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0.addingTimeInterval(0.6)), 1)
    }

    /// A press far from the previous cell is a separate click, not a repeat.
    func testClickFarAwayRestarts() {
        let app = EditorApp(states: [makeState("hello\n")])
        let t0 = Date()
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0), 1)
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 9, at: t0.addingTimeInterval(0.3)), 1)
    }

    /// A drag (or any reset) breaks the sequence so the next press is a fresh 1.
    func testResetBreaksSequence() {
        let app = EditorApp(states: [makeState("hello\n")])
        let t0 = Date()
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0), 1)
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0.addingTimeInterval(0.3)), 2)
        app.resetMouseClickSequence()
        XCTAssertEqual(app.nextMouseClickCount(row: 0, col: 3, at: t0.addingTimeInterval(0.3)), 1)
    }

    // MARK: - Word selection (double click)

    func testDoubleClickSelectsWord() {
        let state = makeState("hello world foo\n")
        state.mousePress(row: 0, col: 7, viewportWidth: 30, clickCount: 2)
        XCTAssertEqual(state.document.selectedText, "world")
        XCTAssertEqual(state.document.selectionRange?.start, CursorPosition(line: 0, column: 6))
        XCTAssertEqual(state.document.selectionRange?.end, CursorPosition(line: 0, column: 11))
    }

    /// Double-click on whitespace has no word to grab; the cursor just moves.
    func testDoubleClickOnWhitespaceSelectsNothing() {
        let state = makeState("hello world\n")
        state.mousePress(row: 0, col: 5, viewportWidth: 30, clickCount: 2)
        XCTAssertEqual(state.document.cursorColumn, 5)
        XCTAssertFalse(state.document.hasSelection)
    }

    /// Underscore joins a word, matching the word-movement commands.
    func testDoubleClickSelectsUnderscoreWord() {
        let state = makeState("some_var value\n")
        state.mousePress(row: 0, col: 5, viewportWidth: 30, clickCount: 2)
        XCTAssertEqual(state.document.selectedText, "some_var")
    }

    /// The click maps through wrapping, so a word on a wrapped visual row
    /// still selects the whole raw word.
    func testDoubleClickSelectsWordOnWrappedRow() {
        let state = makeState("hello world foo\n")
        // viewportWidth 6 wraps: row 0 "hello ", row 1 "world ", row 2 "foo".
        state.mousePress(row: 1, col: 2, viewportWidth: 6, clickCount: 2)
        XCTAssertEqual(state.document.selectedText, "world")
    }

    // MARK: - Line selection (triple click) and toggling

    func testTripleClickSelectsWholeLine() {
        let state = makeState("first line\nsecond line\n")
        state.mousePress(row: 1, col: 3, viewportWidth: 30, clickCount: 3)
        XCTAssertEqual(state.document.selectedText, "second line")
        XCTAssertEqual(state.document.selectionRange?.start, CursorPosition(line: 1, column: 0))
        XCTAssertEqual(state.document.selectionRange?.end, CursorPosition(line: 1, column: 11))
    }

    /// The fourth click toggles back to word selection, and the fifth to line.
    func testFourthAndFifthClicksToggle() {
        let state = makeState("hello world foo\n")
        state.mousePress(row: 0, col: 7, viewportWidth: 30, clickCount: 4)
        XCTAssertEqual(state.document.selectedText, "world")
        state.mousePress(row: 0, col: 7, viewportWidth: 30, clickCount: 5)
        XCTAssertEqual(state.document.selectedText, "hello world foo")
    }

    /// A plain press keeps the current behavior: cursor moves, no selection.
    func testSingleClickPlacesCursorWithoutSelection() {
        let state = makeState("hello world foo\n")
        state.mousePress(row: 0, col: 7, viewportWidth: 30)
        XCTAssertEqual(state.document.cursorColumn, 7)
        XCTAssertFalse(state.document.hasSelection)
    }

    /// Selection survives drag extension: after a double-click the anchor stays
    /// at the word start while the drag moves the cursor.
    func testDragAfterDoubleClickExtendsFromWordStart() {
        let state = makeState("hello world foo\n")
        state.mousePress(row: 0, col: 7, viewportWidth: 30, clickCount: 2)
        state.mouseDrag(row: 0, col: 20, viewportWidth: 30)   // clamps to end of line
        XCTAssertEqual(state.document.selectionRange?.start, CursorPosition(line: 0, column: 6))
        XCTAssertEqual(state.document.selectedText, "world foo")
    }
}
