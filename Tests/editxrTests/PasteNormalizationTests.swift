import XCTest
@testable import editxr

/// A paste carrying classic-Mac CR line endings used to inject raw `\r` into a
/// single document line. The terminal executes `\r` as "return to column 0", so
/// the text overwrote itself, the caret block was wiped, and the command panel
/// spliced over it sheared. These pin the normalization at both entry points
/// (file load and insertion) and the rendered frame's freedom from controls.
final class PasteNormalizationTests: XCTestCase {

    private func makeApp(_ content: String = "seed\nline") -> (EditorApp, EditorState) {
        let tmp = NSTemporaryDirectory() + "editxr-paste-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.showLineNumbers = false
        state.leftMargin = 0
        return (EditorApp(states: [state]), state)
    }

    private let crText = "Informe Antisiniestral\rTodos los establecimientos\r"
        + "Existen dos opciones:\rCertificado Profesional de Seguridad Antisinestral\r\r"

    // MARK: - Load

    func testLoadSplitsCarriageReturnsIntoLines() {
        let doc = Document(content: "A\rB\rC")
        XCTAssertEqual(doc.lines, ["A", "B", "C", ""])
    }

    func testLoadNormalizesCRLF() {
        let doc = Document(content: "A\r\nB\r\n")
        XCTAssertEqual(doc.lines, ["A", "B", ""])
    }

    func testLoadDropsControlCharactersButKeepsTabs() {
        let doc = Document(content: "a\u{0B}b\tc")
        XCTAssertEqual(doc.lines.first, "ab\tc")
    }

    // MARK: - Paste

    func testPasteConvertsCarriageReturnsToLines() {
        let (_, state) = makeApp()
        state.pasteText(crText)
        XCTAssertFalse(state.document.content.contains("\r"))
        XCTAssertTrue(state.document.lines.contains("Informe Antisiniestral"))
        XCTAssertTrue(state.document.lines.contains("Existen dos opciones:"))
    }

    func testPasteKeepsTabs() {
        let (_, state) = makeApp()
        state.pasteText("a\tb")
        XCTAssertTrue(state.document.content.contains("a\tb"))
    }

    func testPasteDropsOtherControlCharacters() {
        let (_, state) = makeApp()
        state.pasteText("x\u{07}y")
        XCTAssertTrue(state.document.content.contains("xy"))
        XCTAssertFalse(state.document.content.contains("\u{07}"))
    }

    // MARK: - Rendered frame

    func testRenderedRowsNeverCarryControlCharacters() {
        let (app, state) = makeApp()
        state.pasteText(crText)
        let rows = app.renderContentLinesForTest(width: 60, height: 24)
        for row in rows {
            XCTAssertFalse(row.contains("\r"),
                "control char leaked into a row: \(row.debugDescription)")
        }
    }

    func testFrameFitsWidthAndKeepsCaretAfterCRPaste() {
        let (app, state) = makeApp()
        state.pasteText(crText)

        let width = 80
        let rows = app.renderEditorLinesForTest(width: width, height: 24)
        for (i, row) in rows.enumerated() {
            XCTAssertFalse(row.contains("\r"), "row \(i) carries a control char")
            XCTAssertLessThanOrEqual(row.displayWidth, width,
                "row \(i) overflows: \(RenderTests.plain(row).debugDescription)")
        }
        XCTAssertTrue(rows.joined().contains(Theme.inverse),
                      "caret vanished after the paste")
    }

    func testCommandPanelFrameFitsWidthAfterCRPaste() {
        let (app, state) = makeApp()
        state.pasteText(crText)
        app.showCommandPanelForTest()

        let width = 80
        let rows = app.renderEditorLinesForTest(width: width, height: 24)
        for (i, row) in rows.enumerated() {
            XCTAssertFalse(row.contains("\r"), "row \(i) carries a control char")
            XCTAssertLessThanOrEqual(row.displayWidth, width,
                "row \(i) overflows: \(RenderTests.plain(row).debugDescription)")
        }
        let visible = rows.map { RenderTests.plain($0) }.joined()
        XCTAssertTrue(visible.contains("Commands"), "the panel is missing from the frame")
    }
}
