import XCTest
@testable import editxr

/// Live search in the command panel: every keystroke re-runs the provider and
/// replaces the rows, rather than fuzzy-filtering a fixed list. Rows are read
/// back through `render`, the same path the terminal draws.
final class VaultSearchPanelTests: XCTestCase {

    /// Visible row text, lowercased — header rows render uppercased, and these
    /// tests are about which rows appear, not how they're cased.
    private func visibleRows(_ panel: CommandPanel) -> [String] {
        guard let out = panel.render(width: 100, height: 30) else { return [] }
        return out.lines.map {
            RenderTests.plain($0).trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    private func type(_ text: String, into panel: CommandPanel) {
        for char in text { panel.handleKey(char) }
    }

    // MARK: - Live rows

    func testRowsFollowEveryKeystroke() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { query in
            query.isEmpty ? [.header("Type to search")]
                          : [PaletteCommand(title: "hit for \(query)", shortcut: "", action: {})]
        }

        XCTAssertTrue(visibleRows(panel).contains { $0.contains("type to search") })

        type("ab", into: panel)
        XCTAssertTrue(visibleRows(panel).contains { $0.contains("hit for ab") })

        panel.handleKey(Key.backspace)
        XCTAssertTrue(visibleRows(panel).contains { $0.contains("hit for a") })
    }

    func testTheMatchedWordIsMarkedInTheRow() throws {
        let panel = CommandPanel()
        panel.show()
        let match = [TextMatch(text: "ruben", isPrefix: false)]
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "Salud › Cáncer de Rubén", shortcut: "", matches: match, action: {}),
             PaletteCommand(title: "Diario › Rubén otra vez", shortcut: "", matches: match, action: {})]
        }
        type("ruben", into: panel)
        let rows = panel.render(width: 100, height: 30)?.lines ?? []

        // The rows still read the same; only the word wears different colours —
        // the selection's on an ordinary row, and the panel's own on the
        // selected row, which already wears the selection.
        let selected = try XCTUnwrap(rows.first { RenderTests.plain($0).contains("Cáncer de Rubén") })
        XCTAssertTrue(selected.contains("\(Theme.statusBarBg)\(Theme.accent)\(Theme.bold)Rubén"),
                      "the matched word was not marked on the selected row")

        let ordinary = try XCTUnwrap(rows.first { RenderTests.plain($0).contains("otra vez") })
        XCTAssertTrue(ordinary.contains("\(Theme.selectionBg)\(Theme.selectionFg)Rubén"),
                      "the matched word was not marked")
    }

    func testAnUnmatchedRowIsLeftAlone() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "Salud › Cáncer de Rubén", shortcut: "", action: {})]
        }
        type("ruben", into: panel)
        let rows = panel.render(width: 100, height: 30)?.lines ?? []
        XCTAssertFalse(rows.contains { $0.contains("\(Theme.selectionBg)\(Theme.selectionFg)Rubén") })
    }

    func testTheProviderRunsOncePerDistinctQueryNotOncePerRead() {
        // The row list is read several times per keystroke (selection, render,
        // activation); a BM25 pass per read would be wasted work.
        var calls = 0
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { query in
            calls += 1
            return [PaletteCommand(title: "row \(query)", shortcut: "", action: {})]
        }
        let afterSetup = calls

        type("x", into: panel)
        _ = visibleRows(panel)
        _ = visibleRows(panel)
        panel.moveSelection(1)

        XCTAssertEqual(calls - afterSetup, 1, "provider ran \(calls - afterSetup) times for one keystroke")
    }

    func testQueryIsNotFuzzyFilteredOnTopOfTheProvider() {
        // The provider already ranked these; the panel must not drop rows whose
        // titles don't fuzzy-match the query.
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "completely unrelated title", shortcut: "", action: {})]
        }
        type("zzzz", into: panel)

        XCTAssertTrue(visibleRows(panel).contains { $0.contains("completely unrelated title") })
    }

    // MARK: - Activation

    func testEnterRunsTheSelectedRow() {
        var opened: String?
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { query in
            [PaletteCommand(title: "note-\(query)", shortcut: "") { opened = "note-\(query)" }]
        }
        type("a", into: panel)
        panel.handleKey(Key.enter)

        XCTAssertEqual(opened, "note-a")
    }

    func testHeaderRowsAreNotActivatable() {
        // "No matches" is a header; Enter on it must do nothing rather than crash.
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in [.header("No matches")] }
        type("zz", into: panel)
        panel.handleKey(Key.enter)

        XCTAssertTrue(panel.isVisible)
    }

    // MARK: - Mode isolation

    func testLiveModeIsClearedWhenAnotherRootIsSet() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "live row", shortcut: "", action: {})]
        }
        panel.setRoot(title: "Commands") {
            [PaletteCommand(title: "static row", shortcut: "", action: {})]
        }

        let rows = visibleRows(panel)
        XCTAssertTrue(rows.contains { $0.contains("static row") })
        XCTAssertFalse(rows.contains { $0.contains("live row") })
    }

    func testLiveModeIsClearedOnHide() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "live row", shortcut: "", action: {})]
        }
        panel.hide()
        panel.setRoot(title: "Commands") {
            [PaletteCommand(title: "static row", shortcut: "", action: {})]
        }
        panel.show()

        XCTAssertFalse(visibleRows(panel).contains { $0.contains("live row") })
    }

    // MARK: - Wide layout and the detail pane

    /// A live level with `count` rows, each previewing `preview`.
    private func searchPanel(count: Int = 4, preview: [String] = ["path.md", "", "body line"]) -> CommandPanel {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            (0..<count).map { i in
                PaletteCommand(title: "result \(i)", shortcut: "",
                               preview: { _ in preview.map { PreviewLine.plain("\($0) [\(i)]") } }) {}
            }
        }
        for char in "q" { panel.handleKey(char) }
        return panel
    }

    func testWideLevelSpreadsAcrossTheScreenLeavingRoomForTheShadow() {
        let panel = searchPanel()
        let out = try! XCTUnwrap(panel.render(width: 120, height: 40))

        XCTAssertEqual(out.width, 112)                       // 120 - 4 either side
        XCTAssertEqual(out.left, 4)
        // The drop shadow is drawn two columns right of the box; it must land
        // on screen rather than past the last column.
        XCTAssertLessThanOrEqual(out.left + out.width + 2, 120)
    }

    func testEveryRowIsExactlyTheBoxWidth() {
        // A drifting row would misalign the separator and the right border.
        let panel = searchPanel()
        let out = try! XCTUnwrap(panel.render(width: 120, height: 40))
        for line in out.lines {
            XCTAssertEqual(RenderTests.plain(line).displayWidth, out.width,
                           "row |\(RenderTests.plain(line))|")
        }
    }

    func testTheDetailPaneShowsTheSelectedRowsContent() {
        let panel = searchPanel()
        let rows = visibleRows(panel)
        // The pane is a column, so its lines sit on their own rows next to the
        // list; what matters is that the selected row's content is the one shown.
        XCTAssertTrue(rows.contains { $0.contains("result 0") })
        XCTAssertTrue(rows.contains { $0.contains("body line [0]") })
        XCTAssertFalse(rows.contains { $0.contains("body line [1]") })
    }

    func testThePreviewFollowsTheSelection() {
        let panel = searchPanel()
        panel.moveSelection(1)
        let rows = visibleRows(panel)
        XCTAssertTrue(rows.contains { $0.contains("body line [1]") })
        XCTAssertFalse(rows.contains { $0.contains("body line [0]") })
    }

    func testTheSearchFieldNeverMovesAsResultsChange() {
        // The whole point of anchoring: typing must not shift the field under
        // the cursor. Same top row and same box height for every result count.
        let shapes = [0, 1, 3, 10, 40].map { count -> (top: Int, rows: Int) in
            let out = try! XCTUnwrap(searchPanel(count: count).render(width: 120, height: 40))
            return (out.top, out.lines.count)
        }
        XCTAssertEqual(Set(shapes.map(\.top)).count, 1, "top row moved: \(shapes.map(\.top))")
        XCTAssertEqual(Set(shapes.map(\.rows)).count, 1, "box resized: \(shapes.map(\.rows))")
    }

    func testTheBoxIsTheSameSizeWhateverThePreviewLength() {
        let short = try! XCTUnwrap(searchPanel(count: 2, preview: ["one line"])
            .render(width: 120, height: 40))
        let tall = try! XCTUnwrap(searchPanel(count: 2, preview: (0..<80).map { "line \($0)" })
            .render(width: 120, height: 40))

        XCTAssertEqual(short.lines.count, tall.lines.count)
        XCTAssertEqual(short.top, tall.top)
    }

    func testTheBoxIsAnchoredNearTheTopNotCentred() {
        let out = try! XCTUnwrap(searchPanel().render(width: 120, height: 40))
        XCTAssertEqual(out.top, CommandPanel.wideTop(height: 40))
        // Spotlight-like: above the middle, and clear of the first row.
        XCTAssertGreaterThanOrEqual(out.top, 2)
        XCTAssertLessThan(out.top, 40 / 2)
    }

    func testTheAnchorHoldsOnASmallTerminalToo() {
        for height in [20, 24, 30, 60] {
            let out = try! XCTUnwrap(searchPanel().render(width: 120, height: height))
            XCTAssertEqual(out.top, CommandPanel.wideTop(height: height))
            XCTAssertLessThanOrEqual(out.top + out.lines.count + 1, height,
                                     "box overflows a \(height)-row screen")
        }
    }

    func testTheBoxStaysWithinTheScreenHeight() {
        let panel = searchPanel(count: 2, preview: (0..<200).map { "line \($0)" })
        let out = try! XCTUnwrap(panel.render(width: 120, height: 30))
        // Room for the shadow row under the box, too.
        XCTAssertLessThanOrEqual(out.top + out.lines.count + 1, 30)
    }

    func testANarrowTerminalFallsBackToOneColumn() {
        let panel = searchPanel()
        let out = try! XCTUnwrap(panel.render(width: 70, height: 40))

        XCTAssertLessThanOrEqual(out.width, 60)
        XCTAssertFalse(out.lines.contains { RenderTests.plain($0).contains("body line") })
    }

    func testOrdinaryMenusAreNotWidened() {
        let panel = CommandPanel()
        panel.setRoot(title: "Commands") {
            [PaletteCommand(title: "static row", shortcut: "", action: {})]
        }
        panel.show()
        let out = try! XCTUnwrap(panel.render(width: 120, height: 40))
        XCTAssertLessThanOrEqual(out.width, 60)
    }

    func testThePreviewProviderIsCachedBetweenRepaints() {
        var calls = 0
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "row", shortcut: "", preview: { _ in calls += 1; return [PreviewLine.plain("body")] }) {}]
        }
        panel.handleKey("q")
        _ = panel.render(width: 120, height: 40)
        let afterFirst = calls
        _ = panel.render(width: 120, height: 40)
        _ = panel.render(width: 120, height: 40)

        XCTAssertEqual(calls, afterFirst, "preview re-read \(calls - afterFirst) times on repaint")
    }

    func testRowsWithoutAPreviewStillRender() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "no preview here", shortcut: "", action: {})]
        }
        panel.handleKey("q")
        let out = try! XCTUnwrap(panel.render(width: 120, height: 40))
        XCTAssertTrue(out.lines.contains { RenderTests.plain($0).contains("no preview here") })
        for line in out.lines {
            XCTAssertEqual(RenderTests.plain(line).displayWidth, out.width)
        }
    }

    func testWideGeometryHoldsWithWideGlyphsInTitlesAndPreview() {
        // Emoji and CJK count as two columns; the split must still line up.
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "🎭 note › 你好 section", shortcut: "",
                            preview: { _ in ["🎭🎭🎭 你好世界 preview line", "second ✅ line"].map(PreviewLine.plain) }) {}]
        }
        panel.handleKey("q")
        let out = try! XCTUnwrap(panel.render(width: 120, height: 40))
        for line in out.lines {
            XCTAssertEqual(RenderTests.plain(line).displayWidth, out.width,
                           "row |\(RenderTests.plain(line))|")
        }
    }

    func testASubmenuOpenedFromLiveSearchFiltersNormallyAndRestoresOnBack() {
        let panel = CommandPanel()
        panel.show()
        panel.setLiveRoot(title: "Search") { _ in
            [PaletteCommand(title: "folder", shortcut: "→", submenu: {
                [PaletteCommand(title: "child alpha", shortcut: "", action: {}),
                 PaletteCommand(title: "child beta", shortcut: "", action: {})]
            }, action: {})]
        }
        type("f", into: panel)
        panel.handleKey(Key.enter)

        // Inside the submenu the normal fuzzy filter applies again.
        type("beta", into: panel)
        let inSubmenu = visibleRows(panel)
        XCTAssertTrue(inSubmenu.contains { $0.contains("child beta") })
        XCTAssertFalse(inSubmenu.contains { $0.contains("child alpha") })

        panel.goBack()
        XCTAssertTrue(visibleRows(panel).contains { $0.contains("folder") })
    }
}
