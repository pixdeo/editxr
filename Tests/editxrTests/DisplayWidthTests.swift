import XCTest
@testable import editxr

/// Terminal column widths for the symbols that show up in Markdown tables.
/// The bug this guards: a blanket "0x2600–0x27BF ⇒ 2" range counted the
/// ambiguous-width symbols ★ ✓ ⚠ as two columns, while Terminal.app draws them
/// as one — so every table row using one drifted a column and the box went
/// ragged. Wide glyphs must be exactly those with default emoji presentation
/// (plus U+FE0F-forced ones).
final class DisplayWidthTests: XCTestCase {

    func testAmbiguousSymbolsAreNarrow() {
        // Text-presentation symbols: one column in the terminal.
        for ch: Character in ["★", "✓", "✔", "⚠", "➡", "☀", "♻", "⌥", "⌫"] {
            XCTAssertEqual(displayWidth(ch), 1, "\(ch) should be one column")
        }
    }

    func testEmojiPresentationSymbolsAreWide() {
        // Default emoji presentation: two columns.
        for ch: Character in ["✅", "⛔", "⏰", "⌚", "🎭", "你"] {
            XCTAssertEqual(displayWidth(ch), 2, "\(ch) should be two columns")
        }
    }

    func testVariationSelectorDoesNotWidenNarrowSymbol() {
        // Terminal.app draws ⚠️ (U+26A0 U+FE0F) as the narrow text glyph — the
        // variation selector does not promote it to a wide emoji cell.
        XCTAssertEqual(displayWidth("⚠️"), 1)   // U+26A0 U+FE0F
        XCTAssertEqual(displayWidth("⚠"), 1)    // bare U+26A0
    }

    func testStringDisplayWidthMixesSymbolsCorrectly() {
        XCTAssertEqual("★".displayWidth, 1)
        XCTAssertEqual("✅ 228".displayWidth, 6)   // 2 + space + "228"
        XCTAssertEqual("⛔".displayWidth, 2)
    }

    // MARK: - Live terminal measurement (probeWidths → registerMeasuredWidths)

    override func tearDown() {
        resetMeasuredWidths()   // keep measured overrides from leaking between tests
        super.tearDown()
    }

    func testMeasuredWidthOverridesHeuristic() {
        // If the terminal reports ⚠️ as two columns, layout must honour that even
        // though the static heuristic defaults it to one.
        XCTAssertEqual(displayWidth("⚠️"), 1)
        registerMeasuredWidths(["⚠️": 2, "★": 2])
        XCTAssertEqual(displayWidth("⚠️"), 2)
        XCTAssertEqual(displayWidth("★"), 2)
        resetMeasuredWidths()
        XCTAssertEqual(displayWidth("⚠️"), 1, "reset restores the heuristic")
    }

    func testMeasuredWidthIgnoresOutOfRangeValues() {
        // 0 / negative / >2 come from a garbled reply and must not be trusted.
        registerMeasuredWidths(["★": 0, "✓": 5])
        XCTAssertEqual(displayWidth("★"), 1)
        XCTAssertEqual(displayWidth("✓"), 1)
    }

    // MARK: - On-disk cache (so a second run probes nothing and starts instantly)

    /// Redirect the cache at a temp file and run `body`, restoring the real path.
    private func withTempCache(_ body: (String) throws -> Void) rethrows {
        let real = GlyphWidthCache.path
        let temp = NSTemporaryDirectory() + "editxr-widths-\(UUID().uuidString).json"
        GlyphWidthCache.path = temp
        defer {
            GlyphWidthCache.path = real
            try? FileManager.default.removeItem(atPath: temp)
        }
        try body(temp)
    }

    func testCachedWidthsSurviveAcrossRuns() {
        withTempCache { _ in
            registerMeasuredWidths(["⚠️": 2, "★": 2])
            GlyphWidthCache.save()
            resetMeasuredWidths()                      // simulate a fresh launch
            XCTAssertFalse(hasMeasuredWidth("⚠️"))
            GlyphWidthCache.load()
            XCTAssertTrue(hasMeasuredWidth("⚠️"), "cached glyphs need no re-probe")
            XCTAssertEqual(displayWidth("⚠️"), 2)
            XCTAssertEqual(displayWidth("★"), 2)
        }
    }

    func testCacheFromAnotherTerminalIsIgnored() {
        withTempCache { path in
            let stale = #"{"terminal":"TERM=some-other-terminal","widths":{"★":2}}"#
            try? stale.write(toFile: path, atomically: true, encoding: .utf8)
            GlyphWidthCache.load()
            XCTAssertFalse(hasMeasuredWidth("★"), "widths measured elsewhere aren't ours")
            XCTAssertEqual(displayWidth("★"), 1, "falls back to the heuristic")
        }
    }

    func testCorruptCacheIsIgnored() {
        withTempCache { path in
            try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
            GlyphWidthCache.load()
            XCTAssertEqual(displayWidth("★"), 1)
        }
    }

    func testParseCPRColumn() {
        XCTAssertEqual(PlatformTerminal.parseCPRColumn("\u{1B}[1;3R"), 3)
        XCTAssertEqual(PlatformTerminal.parseCPRColumn("\u{1B}[24;2R"), 2)
        // Tolerates leading noise before the report.
        XCTAssertEqual(PlatformTerminal.parseCPRColumn("junk\u{1B}[5;2R"), 2)
        XCTAssertNil(PlatformTerminal.parseCPRColumn("\u{1B}[5;garbage"))
        XCTAssertNil(PlatformTerminal.parseCPRColumn(""))
    }
}
