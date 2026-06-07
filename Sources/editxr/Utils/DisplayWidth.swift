import Foundation

/// Number of terminal columns a character occupies (0, 1 or 2).
/// Approximates wcwidth: combining marks are zero-width, CJK/emoji are wide.
func displayWidth(_ char: Character) -> Int {
    guard let scalar = char.unicodeScalars.first else { return 1 }
    let v = scalar.value

    if v == 0 { return 0 }
    // Combining marks / zero-width
    if (0x0300...0x036F).contains(v) || v == 0x200D || (0xFE00...0xFE0F).contains(v) {
        return 0
    }
    // Wide ranges (CJK, Hangul, fullwidth, emoji blocks)
    if (0x1100...0x115F).contains(v) ||
       (0x2300...0x23FF).contains(v) ||
       (0x2600...0x27BF).contains(v) ||
       (0x2E80...0xA4CF).contains(v) ||
       (0xAC00...0xD7A3).contains(v) ||
       (0xF900...0xFAFF).contains(v) ||
       (0xFE30...0xFE4F).contains(v) ||
       (0xFF00...0xFF60).contains(v) ||
       (0xFFE0...0xFFE6).contains(v) ||
       (0x1F000...0x1FAFF).contains(v) {
        return 2
    }
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
