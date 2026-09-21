import XCTest
@testable import editxr

/// Regression: an OSC 8 hyperlink must never cover more than the link's own
/// display text. Terminals draw (on hover, or statically in Terminal.app) an
/// underline under every character inside an open hyperlink region, so any leak
/// draws the underscore "de lado a lado" over whatever is in the way — the
/// wrapped rows below the link, and the command panel when it's spliced over
/// the link's row.
final class LinkWrapTests: XCTestCase {

    // MARK: - Helpers

    private func makeApp(_ content: String, cursorLine: Int) -> EditorApp {
        let tmp = NSTemporaryDirectory() + "editxr-test-\(UUID().uuidString).md"
        try? content.write(toFile: tmp, atomically: true, encoding: .utf8)
        let state = EditorState(filePath: tmp)
        state.wordWrap = true
        state.blockMode = false
        state.document.cursorLine = max(0, min(cursorLine, state.document.lines.count - 1))
        state.document.cursorColumn = 0
        return EditorApp(states: [state])
    }

    /// Count OSC 8 hyperlink opens (`ESC]8;;uri ESC\`, non-empty URI) and
    /// closes (`ESC]8;;ESC\`) in one rendered row.
    private func osc8Counts(_ row: String) -> (opens: Int, closes: Int) {
        let chars = Array(row)
        var opens = 0
        var closes = 0
        var i = 0
        while i < chars.count {
            guard chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "]" else {
                i += 1
                continue
            }
            var k = i + 2
            var payload = ""
            while k < chars.count {
                if chars[k] == "\u{1B}" && k + 1 < chars.count && chars[k + 1] == "\\" { break }
                if chars[k] == "\u{07}" { break }
                payload.append(chars[k])
                k += 1
            }
            let body = String(payload)
            if body == "8;;" { closes += 1 }
            else if body.hasPrefix("8;;") { opens += 1 }
            i = k + 2
        }
        return (opens, closes)
    }

    /// Walk a rendered row the way a terminal does: track whether we're inside
    /// an OSC 8 hyperlink region and report which visible columns are, so tests
    /// can assert that specific content (the panel) never falls inside one.
    private func hyperlinkedColumns(_ row: String) -> Set<Int> {
        let chars = Array(row)
        var out = Set<Int>()
        var inLink = false
        var col = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\u{1B}" {
                let end = ansiEscapeEnd(chars, from: i)
                let esc = String(chars[i..<end])
                if esc.hasPrefix("\u{1B}]8;") {
                    inLink = (esc != Theme.hyperlinkClose)
                }
                i = end
                continue
            }
            if inLink { out.insert(col) }
            col += displayWidth(chars[i])
            i += 1
        }
        return out
    }

    // MARK: - Wrapped links keep the hyperlink balanced on every row

    func testWrappedLinkHyperlinkBalancedPerRow() {
        // The link's display text is longer than the wrap budget, so it spans
        // three rows. Each row must open and close its own hyperlink; otherwise
        // rows 1..n are swallowed into the region and get underlined edge to
        // edge (and a panel spliced over them inherits the underscore).
        let content = """
        Ver el [sitio oficial con un nombre muy largo que se corta](https://example.com/ruta/muy/larga) para mas info
        segunda linea
        """
        let app = makeApp(content, cursorLine: 1)
        let rows = app.renderContentLinesForTest(width: 30, height: 20)

        var sawLink = false
        for (i, row) in rows.enumerated() {
            let (opens, closes) = osc8Counts(row)
            if opens + closes > 0 { sawLink = true }
            XCTAssertEqual(opens, closes,
                "row \(i): OSC 8 hyperlink leaks past the row (opens \(opens) != closes \(closes)):\n\(row.debugDescription)")
        }
        XCTAssertTrue(sawLink, "sanity: the link rows must actually contain OSC 8 sequences")
    }

    // MARK: - A panel spliced over a link must not be absorbed into the hyperlink

    func testPanelSplicedOverLinkIsNotInsideHyperlink() {
        let content = """
        Ver el [sitio oficial](https://example.com) para mas info
        segunda linea
        """
        let app = makeApp(content, cursorLine: 1)
        let base = app.renderContentLinesForTest(width: 80, height: 20)[0]

        // A command-panel row, spliced over the link's display text exactly the
        // way overlayCommandPanel paints the box over the content. The gutter
        // ("1 ") puts "sitio oficial" at columns 11–23, so an insert at
        // column 13 lands inside the link with display text left after it.
        let panel = "\(Theme.accent)│\(Theme.statusBarBg) PANEL \(Theme.accent)│\(Theme.reset)"
        let insertAt = 13
        let insertWidth = panel.displayWidth
        let spliced = app.spliceVisibleForTest(base: base, insert: panel, at: insertAt, insertWidth: insertWidth, width: 80)

        let linkCols = hyperlinkedColumns(spliced)
        let panelCols = Set((insertAt..<(insertAt + insertWidth)))
        let absorbed = panelCols.intersection(linkCols)

        XCTAssertEqual(absorbed, [],
            "panel columns \(absorbed.sorted()) fell inside the link's hyperlink region (the terminal underlines them over the panel):\n\(spliced.debugDescription)")

        // The link text that stays visible after the panel must still be a live
        // hyperlink — closing the region before the panel must not kill the
        // affordance for the rest of the link.
        XCTAssertTrue(linkCols.contains(insertAt + insertWidth),
            "the link text after the panel lost its hyperlink:\n\(spliced.debugDescription)")
    }

    func testPanelSplicedInsideWrappedLinkRowIsNotInsideHyperlink() {
        // Same invariant through the real frame pipeline: open the command
        // panel and render the whole editor; the panel's box borders must never
        // land inside a hyperlink region. The link starts the line (so the
        // panel's left edge falls inside the link text) and sits on the content
        // row the panel box paints over.
        let linkLine = "[sitio oficial con un nombre muy largo que se corta justo en el medio de la fila para que envuelva](https://example.com/ruta/muy/larga) y sigue el texto"
        let padding = String(repeating: "\n", count: 6)
        let content = padding + linkLine + "\nsegunda linea"
        let app = makeApp(content, cursorLine: 7)
        app.showCommandPanelForTest()

        let rows = app.renderEditorLinesForTest(width: 80, height: 24)
        let panelGlyphs = Set("│╭╮╰╯─".map(String.init))
        var panelCharsSeen = 0
        for (i, row) in rows.enumerated() {
            let linkCols = hyperlinkedColumns(row)
            let chars = Array(row)
            var col = 0
            var j = 0
            while j < chars.count {
                if chars[j] == "\u{1B}" {
                    j = ansiEscapeEnd(chars, from: j)
                    continue
                }
                if panelGlyphs.contains(String(chars[j])) {
                    panelCharsSeen += 1
                    XCTAssertFalse(linkCols.contains(col),
                        "row \(i): a panel box border at column \(col) is inside a hyperlink region:\n\(row.debugDescription)")
                }
                col += displayWidth(chars[j])
                j += 1
            }
        }
        XCTAssertGreaterThan(panelCharsSeen, 0, "sanity: the panel box must be visible in the frame")
    }
}
