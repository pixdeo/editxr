import XCTest
@testable import editxr

/// The search panel's detail pane renders Markdown the way the editor does:
/// markers hidden, blocks styled. Assertions run on the visible text plus the
/// declared column width, which the panel trusts for padding.
final class VaultPreviewTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editxr-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Write `text` as a note and return its rendered preview lines.
    private func preview(_ text: String, width: Int = 60, from line: Int = 0) throws -> [PreviewLine] {
        let note = dir.appendingPathComponent("Note.md")
        try Data(text.utf8).write(to: note)
        let app = EditorApp(states: [EditorState(filePath: note.path)])
        return app.vaultPreviewLinesForTest(path: note.path, from: line, width: width)
    }

    private func visible(_ lines: [PreviewLine]) -> [String] {
        lines.map { RenderTests.plain($0.styled) }
    }

    // MARK: - The invariant the panel depends on

    func testDeclaredWidthMatchesTheVisibleWidthOfEveryLine() throws {
        // The panel pads by `width`; if it lies, the separator and the right
        // border drift out of alignment.
        let lines = try preview("""
        # Title
        Some **bold** and `code` and a [link](x.md).
        - [x] done
        > quote
        ```swift
        let x = 1
        ```
        🎭 emoji and 你好 wide glyphs
        """)
        for line in lines {
            XCTAssertEqual(line.width, RenderTests.plain(line.styled).displayWidth,
                           "line |\(RenderTests.plain(line.styled))|")
        }
    }

    func testLinesAreTruncatedToThePaneWidth() throws {
        let long = String(repeating: "palabra ", count: 40)
        let lines = try preview("# T\n\(long)", width: 24)
        for line in lines {
            XCTAssertLessThanOrEqual(line.width, 24)
            XCTAssertLessThanOrEqual(RenderTests.plain(line.styled).displayWidth, 24)
        }
    }

    func testTruncationDoesNotSplitAWideGlyph() throws {
        // A double-width glyph straddling the edge would overflow by a column.
        let lines = try preview("# T\n" + String(repeating: "你", count: 40), width: 21)
        for line in lines {
            XCTAssertLessThanOrEqual(RenderTests.plain(line.styled).displayWidth, 21)
        }
    }

    // MARK: - Markdown rendering

    func testInlineMarkersAreHidden() throws {
        let text = try visible(preview("Start at **6am**, no *phone* and `no slack`."))
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Start at 6am, no phone and no slack."))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("`"))
    }

    func testHeadingsDropTheirHashes() throws {
        let text = try visible(preview("# Deep Work\n## Rituals\n### Detail"))
        XCTAssertTrue(text.contains("Deep Work"))
        XCTAssertTrue(text.contains("Rituals"))
        XCTAssertFalse(text.contains { $0.contains("#") })
    }

    func testTaskAndBulletMarkersBecomeGlyphs() throws {
        let text = try visible(preview("- [ ] wake up\n- [x] write\n- plain bullet"))
        XCTAssertTrue(text.contains { $0.contains("☐ wake up") })
        XCTAssertTrue(text.contains { $0.contains("☑ write") })
        XCTAssertTrue(text.contains { $0.contains("• plain bullet") })
    }

    func testBlockquotesGetARule() throws {
        let text = try visible(preview("> protect the first block"))
        XCTAssertTrue(text.contains { $0.contains("│ protect the first block") })
    }

    func testLinkTextIsShownWithoutItsTarget() throws {
        let text = try visible(preview("A [[wikilink]] and a [normal](x.md) link."))
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("A wikilink and a normal link."))
        XCTAssertFalse(text.contains("x.md"))
    }

    func testCodeBlockContentIsKeptVerbatim() throws {
        // Inside a fence, ** and ` are code, not markup.
        let text = try visible(preview("```swift\nlet a = **b** `c`\n```"))
        XCTAssertTrue(text.contains { $0.contains("let a = **b** `c`") })
    }

    func testStylingIsAppliedNotJustStripped() throws {
        let lines = try preview("# Heading\nplain line")
        let heading = lines.first { RenderTests.plain($0.styled).contains("Heading") }
        XCTAssertNotNil(heading)
        XCTAssertTrue(heading!.styled.contains("\u{1B}["), "heading came through unstyled")
    }

    // MARK: - Source of the text

    func testThePreviewStartsAtTheMatchedSection() throws {
        let lines = try preview("# One\nalpha\n# Two\nbeta", from: 2)
        let text = visible(lines).joined(separator: "\n")
        XCTAssertTrue(text.contains("Two"))
        XCTAssertFalse(text.contains("alpha"))
    }

    func testTheFirstLineNamesTheNote() throws {
        let lines = try preview("# Title\nbody")
        XCTAssertTrue(RenderTests.plain(lines[0].styled).contains("Note.md"))
    }

    func testALongPathKeepsTheNoteNameAndLosesThePrefix() throws {
        // Trimming from the right would drop the one part that identifies the
        // note, leaving a header of directories.
        let lines = try preview("# Title\nbody", width: 14)
        let header = RenderTests.plain(lines[0].styled)
        XCTAssertTrue(header.hasSuffix("Note.md"), "header was |\(header)|")
        XCTAssertLessThanOrEqual(header.displayWidth, 14)
    }

    func testUnsavedEditsWinOverWhatIsOnDisk() throws {
        // Showing stale text for a note the user is editing would be a lie.
        let note = dir.appendingPathComponent("Note.md")
        try Data("# On disk\nold body".utf8).write(to: note)

        let state = EditorState(filePath: note.path)
        state.document.lines = ["# In buffer", "new body"]
        let app = EditorApp(states: [state])

        let text = visible(app.vaultPreviewLinesForTest(path: note.path, from: 0, width: 60))
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("In buffer"))
        XCTAssertFalse(text.contains("old body"))
    }

    func testAnUnreadableNoteReportsItselfInsteadOfCrashing() throws {
        let missing = dir.appendingPathComponent("gone.md").path
        let app = EditorApp(states: [EditorState(filePath: dir.appendingPathComponent("a.md").path)])
        let lines = app.vaultPreviewLinesForTest(path: missing, from: 0, width: 60)

        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(visible(lines).joined().contains("gone.md"))
    }

    func testAZeroWidthPaneAsksForNothing() throws {
        XCTAssertTrue(try preview("# Title\nbody", width: 0).isEmpty)
    }
}
