import XCTest
@testable import editxr

/// Wheel scrolling repaints as fast as events arrive, so what a frame costs is
/// behaviour: too much and the view falls behind the wheel. These count the work
/// rather than time it, so they hold on any machine.
final class ScrollCostTests: XCTestCase {

    private let longLine = String(repeating: "palabra ", count: 40)

    override func tearDown() {
        resetMeasuredWidths()
        super.tearDown()
    }

    private func document(lines: Int) -> EditorState {
        let state = EditorState(filePath: "/tmp/editxr-scroll-cost-\(UUID().uuidString).md")
        state.document.lines = (0..<lines).map { "\($0) \(longLine)" }
        return state
    }

    // MARK: - Wrapping

    func testAnUnchangedLineIsOnlyWrappedOnce() {
        let line = "a line nobody wrapped yet \(UUID().uuidString) \(longLine)"
        let first = wrapTextRows(line, width: 40, tabStop: 4)
        let misses = WrapCache.misses
        let second = wrapTextRows(line, width: 40, tabStop: 4)
        XCTAssertEqual(WrapCache.misses, misses)
        XCTAssertEqual(first.map(\.segment), second.map(\.segment))
        XCTAssertEqual(first.map(\.startOffset), second.map(\.startOffset))
    }

    func testRowsFollowTheWidthAndTheTabStop() {
        let line = "\tone two three four five six seven eight \(UUID().uuidString)"
        XCTAssertNotEqual(wrapTextRows(line, width: 20, tabStop: 4).count,
                          wrapTextRows(line, width: 40, tabStop: 4).count)
        XCTAssertNotEqual(wrapTextRows(line, width: 40, tabStop: 4).first?.segment,
                          wrapTextRows(line, width: 40, tabStop: 16).first?.segment)
    }

    func testRowsFollowANewlyMeasuredGlyphWidth() {
        // Terminals disagree on these glyphs, so their width is only known once
        // probed; rows wrapped before that are wrong afterwards.
        let glyph: Character = "☕"
        let line = String(repeating: glyph, count: 6)
        registerMeasuredWidths([glyph: 1])
        XCTAssertEqual(wrapTextRows(line, width: 6, tabStop: 4).count, 1)
        registerMeasuredWidths([glyph: 2])
        XCTAssertEqual(wrapTextRows(line, width: 6, tabStop: 4).count, 2)
    }

    // MARK: - The wheel

    func testAWheelBurstCostsOnePassOverTheDocumentNotOnePerLine() {
        // The cursor is dragged along one row at a time; re-deriving where it is
        // from the top of the note on each of those rows is what made the view
        // fall further behind the faster the wheel turned.
        let lines = 200
        let state = document(lines: lines)
        let before = WrapCache.lookups
        state.scrollViewport(lines: 60, viewportHeight: 40, viewportWidth: 80)
        XCTAssertGreaterThan(state.document.cursorLine, 0, "the cursor was not dragged along")
        // One pass over the note, then a few per row the cursor stepped through.
        XCTAssertLessThanOrEqual(WrapCache.lookups - before, lines + 60 * 3)
    }

    func testAWheelBurstLandsWhereSmallStepsLand() {
        let burst = document(lines: 200)
        burst.scrollViewport(lines: 60, viewportHeight: 40, viewportWidth: 80)
        let steps = document(lines: 200)
        for _ in 0..<20 { steps.scrollViewport(lines: 3, viewportHeight: 40, viewportWidth: 80) }
        XCTAssertEqual(burst.scrollOffset, steps.scrollOffset)
        XCTAssertEqual(burst.document.cursorLine, steps.document.cursorLine)
    }
}
