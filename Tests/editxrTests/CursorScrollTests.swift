import XCTest
@testable import editxr

/// The caret is an inverse-video block drawn inside the content, so "the cursor
/// is visible" means the frame contains an inverse sequence. Scroll math counts
/// rows independently of the renderer, so any disagreement between the two ends
/// with the cursor scrolled off screen — that's what these guard.
final class CursorScrollTests: XCTestCase {

    private func makeApp(_ content: String, cursorLine: Int) -> (EditorApp, EditorState) {
        let tmp = NSTemporaryDirectory() + "editxr-cursor-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.showLineNumbers = false
        state.document.cursorLine = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorColumn = 0
        return (EditorApp(states: [state]), state)
    }

    /// A document whose table rows are far wider than the viewport: as raw text
    /// each wraps to several rows, but the renderer draws each as one boxed row.
    private func documentWithWideTable(rowsAfter: Int) -> String {
        let cell = String(repeating: "texto largo de una celda ", count: 20)
        var lines = ["# Title", "", "Intro paragraph.", ""]
        lines.append("| Entidad | Detalle |")
        lines.append("|---|---|")
        for i in 1...12 { lines.append("| Fila \(i) | \(cell) |") }
        lines.append("")
        for i in 1...rowsAfter { lines.append("Line \(i) after the table.") }
        return lines.joined(separator: "\n") + "\n"
    }

    func testCursorStaysVisibleBelowAWideTable() {
        let content = documentWithWideTable(rowsAfter: 60)
        let lineCount = content.components(separatedBy: "\n").count
        for cursorLine in 0..<(lineCount - 1) {
            let (app, _) = makeApp(content, cursorLine: cursorLine)
            let frame = app.renderEditorLinesForTest(width: 100, height: 30).joined(separator: "\n")
            XCTAssertTrue(frame.contains(Theme.inverse),
                          "cursor not drawn with the caret on line \(cursorLine)")
        }
    }

    /// The scroll offset the renderer is given must address a row that exists:
    /// counting a collapsed table row as its raw wrapped height pushed the
    /// viewport past the end of the document.
    func testScrollOffsetStaysWithinTheRenderedDocument() {
        let content = documentWithWideTable(rowsAfter: 10)
        let (app, state) = makeApp(content, cursorLine: state_lastLine(content))
        _ = app.renderEditorLinesForTest(width: 100, height: 30)
        XCTAssertLessThan(state.scrollOffset, state.document.lines.count,
                          "scroll offset ran past the document")
    }

    private func state_lastLine(_ content: String) -> Int {
        content.components(separatedBy: "\n").count - 2
    }
}
