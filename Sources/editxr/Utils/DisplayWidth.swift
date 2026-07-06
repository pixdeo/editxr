import Foundation

/// Number of terminal columns a character occupies (0, 1 or 2).
/// Approximates wcwidth: combining marks are zero-width, CJK/emoji are wide.
func displayWidth(_ char: Character) -> Int {
    guard let scalar = char.unicodeScalars.first else { return 1 }
    let v = scalar.value

    if v == 0 { return 0 }
    // Combining marks / zero-width joiner / lone variation selectors.
    if (0x0300...0x036F).contains(v) || v == 0x200D || (0xFE00...0xFE0F).contains(v) {
        return 0
    }
    // An emoji variation selector (U+FE0F) forces wide emoji presentation on an
    // otherwise-narrow base symbol, e.g. ⚠️ (U+26A0 U+FE0F) or ▶️. Check the
    // whole grapheme, since the base scalar alone reads as text-presentation.
    if char.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
        return 2
    }
    // Unambiguously wide blocks (CJK, Hangul, fullwidth, dedicated emoji planes).
    if (0x1100...0x115F).contains(v) ||
       (0x2E80...0xA4CF).contains(v) ||
       (0xAC00...0xD7A3).contains(v) ||
       (0xF900...0xFAFF).contains(v) ||
       (0xFE30...0xFE4F).contains(v) ||
       (0xFF00...0xFF60).contains(v) ||
       (0xFFE0...0xFFE6).contains(v) ||
       (0x1F000...0x1FAFF).contains(v) {
        return 2
    }
    // Miscellaneous Symbols + Dingbats (0x2600–0x27BF) and Miscellaneous
    // Technical (0x2300–0x23FF) are *ambiguous width*: terminals like
    // Terminal.app render most of them narrow (★ U+2605, ✓ U+2713, ⚠ U+26A0,
    // ⌥ U+2325) and only those with default emoji presentation wide (✅ ⛔ ⏰ ⌚).
    // Deferring to the Unicode property matches that — a blanket wide range here
    // over-counts the narrow symbols and shifts every table column that uses one.
    if char.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
        return 2
    }
    return 1
}

extension StringProtocol {
    /// Visible terminal width, ignoring ANSI escape sequences.
    var displayWidth: Int {
        var width = 0
        var inEscape = false
        for ch in self {
            if ch == "\u{1B}" {
                inEscape = true
            } else if inEscape {
                if ch.isLetter { inEscape = false }
            } else {
                width += editxr_displayWidth(ch)
            }
        }
        return width
    }
}

// Internal alias so the extension can call the free function unambiguously.
@inline(__always)
func editxr_displayWidth(_ char: Character) -> Int { displayWidth(char) }
