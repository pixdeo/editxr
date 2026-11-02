import XCTest
@testable import editxr

/// Mouse reports are screen coordinates, so they have to be read against the
/// frame on screen: with the vault's sidebar docked the note is narrower and
/// starts further right than the terminal is wide.
final class MouseLayoutTests: XCTestCase {

    private let width = 160
    private let height = 50
    private let wheelDown = "\u{1B}[<65;100;20M"
    private let wheelUp = "\u{1B}[<64;100;20M"
    private var savedRoot: String?
    private var filePath = ""

    override func setUp() {
        super.setUp()
        savedRoot = Vault.commandLineRoot
        let root = NSTemporaryDirectory() + "editxr-mouse-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        filePath = root + "/note.md"
        let text = (0..<120).map { "\($0) " + String(repeating: "palabra ", count: 60) }
            .joined(separator: "\n")
        try? text.write(toFile: filePath, atomically: true, encoding: .utf8)
        Vault.commandLineRoot = root
    }

    override func tearDown() {
        Vault.commandLineRoot = savedRoot
        super.tearDown()
    }

    private func app(sidebar: Bool = true) -> EditorApp {
        let state = EditorState(filePath: filePath)
        state.wordWrap = true
        state.showLineNumbers = false
        state.leftMargin = 0
        if sidebar { state.sidebarMode = .files }
        let app = EditorApp(states: [state])
        frame(app)
        return app
    }

    private func frame(_ app: EditorApp) {
        _ = app.renderEditorLinesForTest(width: width, height: height)
    }

    private func scroll(_ app: EditorApp, _ report: String, times: Int) {
        for _ in 0..<times {
            app.mouseReportsForTest(report)
            frame(app)
        }
    }

    func testTheWheelMovesTheViewThreeRowsANotchBesideTheSidebar() {
        let app = app()
        scroll(app, wheelDown, times: 60)
        XCTAssertEqual(app.scrollOffsetForTest, 180)
    }

    func testTheWheelComesBackToWhereItStartedBesideTheSidebar() {
        let app = app()
        scroll(app, wheelDown, times: 60)
        scroll(app, wheelUp, times: 60)
        XCTAssertEqual(app.scrollOffsetForTest, 0)
    }

    func testTheWheelNeverJumpsBesideTheSidebar() {
        let app = app()
        var offset = app.scrollOffsetForTest
        for _ in 0..<100 {
            scroll(app, wheelDown, times: 1)
            XCTAssertEqual(app.scrollOffsetForTest - offset, 3)
            offset = app.scrollOffsetForTest
        }
    }

    func testAClickLandsOnTheColumnUnderThePointerBesideTheSidebar() {
        let app = app()
        // Column 40 of the note: sidebar + separator + 40, 1-based.
        app.mouseReportsForTest("\u{1B}[<0;\(28 + 1 + 40 + 1);2M")
        XCTAssertEqual(app.activeCursorColumnForTest, 40)
    }

    func testAClickLandsOnTheRowUnderThePointerBelowTheTabStrip() {
        let first = EditorState(filePath: filePath)
        first.wordWrap = true
        first.showLineNumbers = false
        first.leftMargin = 0
        let app = EditorApp(states: [first, EditorState(filePath: filePath)])
        frame(app)
        // The note's first row sits under the tab strip and the top bar.
        app.mouseReportsForTest("\u{1B}[<0;11;3M")
        XCTAssertEqual(app.activeCursorLineForTest, 0)
        XCTAssertEqual(app.activeCursorColumnForTest, 10)
    }

    func testAMouseReportCutBetweenTwoReadsNeverReachesTheNote() {
        let app = app(sidebar: false)
        let before = app.activeDocumentLinesForTest
        for cut in 1..<wheelDown.count {
            let split = wheelDown.index(wheelDown.startIndex, offsetBy: cut)
            app.handleInputForTest(String(wheelDown[..<split]))
            app.handleInputForTest(String(wheelDown[split...]))
        }
        XCTAssertEqual(app.activeDocumentLinesForTest, before)
    }

    func testAnEscapeKeyPressStillArrivesOnItsOwn() {
        let app = app(sidebar: false)
        app.showCommandPanelForTest()
        app.handleInputForTest("\u{1B}")
        let settled = expectation(description: "the held escape was released")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertFalse(app.commandPanelVisibleForTest)
    }
}
