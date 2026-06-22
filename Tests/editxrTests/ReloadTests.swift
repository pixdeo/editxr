import XCTest
@testable import editxr

/// External-change detection and reload (Ctrl-P reload + auto-reload-when-clean).
final class ReloadTests: XCTestCase {

    private func tempFile(_ content: String) -> String {
        let path = NSTemporaryDirectory() + "editxr-reload-\(UUID().uuidString).md"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Rewrite a file and stamp it with a newer mtime so detection is reliable
    /// regardless of filesystem timestamp granularity.
    private func rewrite(_ path: String, _ content: String, secondsAhead: TimeInterval = 10) {
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        let future = Date().addingTimeInterval(secondsAhead)
        try? FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: path)
    }

    func testCheckExternalChangeFiresOnceThenStaysFlagged() {
        let path = tempFile("original\n")
        let state = EditorState(filePath: path)
        XCTAssertFalse(state.fileChangedExternally)
        XCTAssertFalse(state.checkExternalChange(), "no change yet")

        rewrite(path, "changed outside\n")
        XCTAssertTrue(state.checkExternalChange(), "should detect the external write")
        XCTAssertTrue(state.fileChangedExternally)
        XCTAssertFalse(state.checkExternalChange(), "must not re-fire while already flagged")
    }

    func testReloadFromDiskPicksUpNewContentAndPreservesCursor() {
        let path = tempFile("line one\nline two\nline three\n")
        let state = EditorState(filePath: path)
        state.document.cursorLine = 1
        state.document.cursorColumn = 3

        rewrite(path, "fresh one\nfresh two\nfresh three\n")
        state.reloadFromDisk()

        XCTAssertTrue(state.document.content.contains("fresh two"))
        XCTAssertFalse(state.isDirty)
        XCTAssertFalse(state.fileChangedExternally, "reload clears the external-change flag")
        XCTAssertEqual(state.document.cursorLine, 1, "cursor line preserved")
        XCTAssertEqual(state.document.cursorColumn, 3, "cursor column preserved")
    }

    func testReloadClampsCursorWhenFileShrinks() {
        let path = tempFile("a\nb\nc\nd\ne\n")
        let state = EditorState(filePath: path)
        state.document.cursorLine = 4
        state.document.cursorColumn = 0

        rewrite(path, "only one line")
        state.reloadFromDisk()

        XCTAssertLessThanOrEqual(state.document.cursorLine, state.document.lines.count - 1,
                                 "cursor line clamped into the shrunken file")
        let line = state.document.lines[state.document.cursorLine]
        XCTAssertLessThanOrEqual(state.document.cursorColumn, line.count,
                                 "cursor column clamped to its line")
    }

    func testSaveResetsExternalChangeFlag() {
        let path = tempFile("body\n")
        let state = EditorState(filePath: path)
        rewrite(path, "outside edit\n")
        XCTAssertTrue(state.checkExternalChange())

        // Saving our buffer wins and re-syncs the known mtime.
        state.save()
        XCTAssertFalse(state.fileChangedExternally)
        XCTAssertFalse(state.checkExternalChange(), "after save, our version is the known one")
    }
}
