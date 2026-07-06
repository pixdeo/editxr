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

    func testVariationSelectorForcesWide() {
        // A narrow base symbol + U+FE0F renders as a wide emoji.
        XCTAssertEqual(displayWidth("⚠️"), 2)   // U+26A0 U+FE0F
        XCTAssertEqual(displayWidth("⚠"), 1)    // bare U+26A0
    }

    func testStringDisplayWidthMixesSymbolsCorrectly() {
        XCTAssertEqual("★".displayWidth, 1)
        XCTAssertEqual("✅ 228".displayWidth, 6)   // 2 + space + "228"
        XCTAssertEqual("⛔".displayWidth, 2)
    }
}
