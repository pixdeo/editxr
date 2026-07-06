import XCTest
@testable import editxr

/// Focus + navigation of the docked sidebar (Tab to focus, arrows/jk, Enter,
/// folder collapse). The pure tree/outline layout is covered in OutlineTests;
/// here we drive the focused-panel key routing.
final class SidebarNavTests: XCTestCase {

    /// A small on-disk project so the file explorer has a real tree to scan.
    private func makeProject() -> String {
        let root = NSTemporaryDirectory() + "editxr-proj-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root + "/src/app", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/docs", withIntermediateDirectories: true)
        try? "x".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        try? "y".write(toFile: root + "/src/util.swift", atomically: true, encoding: .utf8)
        try? "z".write(toFile: root + "/src/app/main.swift", atomically: true, encoding: .utf8)
        try? "g".write(toFile: root + "/docs/guide.md", atomically: true, encoding: .utf8)
        return root
    }

    private func filesApp() -> EditorApp {
        let root = makeProject()
        let state = EditorState(filePath: root + "/README.md")
        state.sidebarMode = .files
        let app = EditorApp(states: [state])
        return app
    }

    // MARK: - Outline navigation

    func testFocusStartsOnCurrentSectionAndArrowsMove() {
        let path = NSTemporaryDirectory() + "editxr-nav-\(UUID().uuidString).md"
        try? "# A\n\nbody\n\n## B\n\nmore\n\n## C\n".write(toFile: path, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: path)
        state.sidebarMode = .outline
        state.document.cursorLine = 5    // inside section "B" (line 4)
        let app = EditorApp(states: [state])

        app.focusSidebarForTest()
        XCTAssertTrue(app.sidebarFocusedForTest)
        XCTAssertEqual(app.sidebarSelectionForTest, 1, "selection starts on the current section (B)")

        app.sidebarKeyForTest("\u{1B}[B")   // down
        XCTAssertEqual(app.sidebarSelectionForTest, 2)
        app.sidebarKeyForTest("\u{1B}[A")   // up
        XCTAssertEqual(app.sidebarSelectionForTest, 1)
    }

    func testOutlineEnterJumpsCursorAndUnfocuses() {
        let path = NSTemporaryDirectory() + "editxr-nav-\(UUID().uuidString).md"
        try? "# A\n\nbody\n\n## B\n\nmore\n\n## C\n".write(toFile: path, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: path)
        state.sidebarMode = .outline
        let app = EditorApp(states: [state])

        app.focusSidebarForTest()
        app.setSidebarSelectionForTest(2)     // heading "C" at line 8
        app.sidebarKeyForTest("\r")
        XCTAssertEqual(app.activeCursorLineForTest, 8, "jumped to heading C")
        XCTAssertFalse(app.sidebarFocusedForTest, "jump returns focus to the editor")
    }

    func testEscapeReturnsFocusToEditor() {
        let app = filesApp()
        app.focusSidebarForTest()
        app.sidebarKeyForTest("\u{1B}")       // Esc
        XCTAssertFalse(app.sidebarFocusedForTest)
    }

    // MARK: - File explorer navigation

    func testCollapseAndExpandFolderChangesRowCount() {
        let app = filesApp()
        app.focusSidebarForTest()
        // Find a non-empty folder (docs or src) and select it.
        let count0 = app.sidebarEntryCountForTest()
        var folderIdx: Int? = nil
        for i in 0..<count0 where app.sidebarEntryForTest(i).isDir {
            folderIdx = i; break
        }
        let idx = try! XCTUnwrap(folderIdx)
        app.setSidebarSelectionForTest(idx)

        app.sidebarKeyForTest("\u{1B}[D")     // collapse (left)
        let collapsed = app.sidebarEntryCountForTest()
        XCTAssertLessThan(collapsed, count0, "collapsing a folder hides its children")

        app.sidebarKeyForTest("\u{1B}[C")     // expand (right)
        XCTAssertEqual(app.sidebarEntryCountForTest(), count0, "expanding restores them")
    }

    func testEnterOnFileOpensIt() {
        let app = filesApp()
        app.focusSidebarForTest()
        // Select the first file entry and open it.
        let n = app.sidebarEntryCountForTest()
        var fileIdx: Int? = nil
        for i in 0..<n where !app.sidebarEntryForTest(i).isDir {
            fileIdx = i; break
        }
        let idx = try! XCTUnwrap(fileIdx)
        let wantPath = app.sidebarEntryForTest(idx).path
        app.setSidebarSelectionForTest(idx)
        app.sidebarKeyForTest("\r")

        XCTAssertTrue(app.activeFileForTest.hasSuffix(wantPath),
                      "opened \(app.activeFileForTest), expected …/\(wantPath)")
        XCTAssertFalse(app.sidebarFocusedForTest, "opening a file returns focus to the editor")
    }
}
