import XCTest
@testable import editxr

/// ESC-prefixed input handling: Option/Alt combos arrive as ESC + more bytes,
/// sometimes split across reads. A lone ESC must wait briefly before acting,
/// and unbound Alt combos must never leak into the document as text.
final class InputSequenceTests: XCTestCase {

    private func makeFile(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "editxr-input-\(UUID().uuidString).md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeApp(_ contents: [String] = ["hello world foo\n"]) -> (EditorApp, [EditorState]) {
        let states = contents.map { EditorState(filePath: makeFile($0)) }
        return (EditorApp(states: states), states)
    }

    // MARK: - Option+Delete (ESC + DEL)

    /// One read: the existing word-delete path keeps working.
    func testOptionBackspaceSingleReadDeletesWord() {
        let (app, states) = makeApp()
        states[0].document.cursorColumn = 15   // end of "hello world foo"
        app.handleInputForTest("\u{1B}\u{7F}")
        XCTAssertEqual(states[0].document.lines[0], "hello world ")
    }

    /// Split across two reads the ESC must not fire on its own (tab jump) and
    /// the DEL must still complete the word delete.
    func testOptionBackspaceSplitReadsDeletesWordWithoutTabJump() {
        let (app, states) = makeApp(["hello world foo\n", "other doc\n"])
        // Build tab history so a stray lone ESC would visibly jump tabs.
        app.handleInputForTest("\u{0E}")   // Ctrl+N → tab 2
        app.handleInputForTest("\u{0E}")   // Ctrl+N → back to tab 1
        XCTAssertEqual(app.activeTabForTest, 0)

        states[0].document.cursorColumn = 15
        app.handleInputForTest("\u{1B}")   // ESC arrives alone…
        app.handleInputForTest("\u{7F}")   // …DEL right behind it
        XCTAssertEqual(app.activeTabForTest, 0, "lone ESC must not switch tabs")
        XCTAssertEqual(states[0].document.lines[0], "hello world ")
    }

    // MARK: - Ctrl+W / Ctrl+J (iTerm2 sends ^W for Option+Backspace)

    /// iTerm2's Natural Text Editing preset sends 0x17 (Ctrl+W) for ⌥⌫, so
    /// Ctrl+W deletes the word backward — it must never close a tab or quit.
    func testCtrlWDeletesWordAndKeepsTabs() {
        let (app, states) = makeApp(["hello world foo\n", "other doc\n"])
        states[0].document.cursorColumn = 15
        app.handleInputForTest("\u{17}")
        XCTAssertEqual(app.tabCountForTest, 2, "Ctrl+W must not close the tab")
        XCTAssertEqual(states[0].document.lines[0], "hello world ")
    }

    /// Close tab moved to Ctrl+J (0x0A; distinct from Enter since ICRNL is off).
    func testCtrlJClosesTab() {
        let (app, _) = makeApp(["hello world foo\n", "other doc\n"])
        XCTAssertEqual(app.tabCountForTest, 2)
        app.handleInputForTest("\u{0A}")
        XCTAssertEqual(app.tabCountForTest, 1)
    }

    // MARK: - Unbound Alt combos

    /// Option+F is ESC f: unbound, so nothing is typed into the document.
    func testOptionLetterDoesNotInsertText() {
        let (app, states) = makeApp()
        app.handleInputForTest("\u{1B}f")
        XCTAssertEqual(states[0].document.lines[0], "hello world foo")
    }

    /// The parser consumes ESC + unbound byte instead of passing it through.
    func testParserSwallowsUnknownAltCombo() {
        let parser = ArrowKeyParser()
        XCTAssertTrue(parser.parse(character: "\u{1B}"))
        XCTAssertTrue(parser.parse(character: "f"))
        XCTAssertNil(parser.arrowKey)
        XCTAssertFalse(parser.altDelete)
    }

    /// A second ESC restarts the sequence: ESC ESC [ A is still Arrow-Up.
    func testParserRecoversFromDoubleEscape() {
        let parser = ArrowKeyParser()
        XCTAssertTrue(parser.parse(character: "\u{1B}"))
        XCTAssertTrue(parser.parse(character: "\u{1B}"))
        XCTAssertTrue(parser.parse(character: "["))
        XCTAssertTrue(parser.parse(character: "A"))
        XCTAssertEqual(parser.arrowKey, .up)
    }

    // MARK: - Plain Escape still works

    /// After the brief hold expires, a lone ESC goes back to the previous tab.
    func testLoneEscapeGoesToPreviousTabAfterTimeout() {
        let (app, _) = makeApp(["hello world foo\n", "other doc\n"])
        app.handleInputForTest("\u{0E}")   // Ctrl+N → tab 2
        XCTAssertEqual(app.activeTabForTest, 1)
        app.handleInputForTest("\u{1B}")
        let fired = expectation(description: "escape hold expires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fired.fulfill() }
        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(app.activeTabForTest, 0)
    }
}
