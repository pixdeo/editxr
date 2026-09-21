import Foundation

/// Incremental scanner that tells visible glyphs apart from ANSI escape bytes.
///
/// The naive rule ("an escape ends at the first letter") only holds for SGR
/// sequences. It breaks on OSC strings: a markdown link is emitted as
/// `ESC ] 8 ; ; https://example.com ESC \`, and the rule ends the escape at the
/// `h` of `http`, so the whole URI is counted as visible text. Every column
/// computed for that line is then wrong — panels spliced over it land in the
/// middle of a later escape and leak fragments like `0m` into the screen.
///
/// This follows the actual grammar instead: CSI (`ESC [` … final `@`–`~`),
/// string sequences (`ESC ]`/`P`/`X`/`^`/`_` … BEL or `ESC \`), `ESC` plus
/// intermediates and a final byte, and plain two-character escapes.
struct ANSIScanner {
    private enum State {
        case ground        // outside any escape
        case escape        // just saw ESC
        case escIntermediate
        case csi
        case string        // OSC/DCS/APC/PM body
        case stringEscape  // saw ESC inside a string body: ST if `\` follows
    }

    private var state: State = .ground

    /// True while `char` is part of an escape sequence, i.e. takes no columns.
    mutating func consume(_ char: Character) -> Bool {
        let byte = char.asciiValue
        switch state {
        case .ground:
            guard char == "\u{1B}" else { return false }
            state = .escape
            return true

        case .escape:
            switch char {
            case "[": state = .csi
            case "]", "P", "X", "^", "_": state = .string
            case "\u{1B}": state = .escape
            default:
                // 0x20–0x2F are intermediates (e.g. `ESC ( B`); anything else is
                // a complete two-character escape.
                state = (byte.map { (0x20...0x2F).contains($0) } ?? false) ? .escIntermediate : .ground
            }
            return true

        case .escIntermediate:
            if let byte, (0x30...0x7E).contains(byte) { state = .ground }
            return true

        case .csi:
            if let byte, (0x40...0x7E).contains(byte) { state = .ground }
            return true

        case .string:
            if char == "\u{07}" { state = .ground }
            else if char == "\u{1B}" { state = .stringEscape }
            return true

        case .stringEscape:
            state = char == "\\" ? .ground : .string
            return true
        }
    }
    /// True while inside an escape sequence (ESC seen, sequence not yet
    /// complete). `consume` returns true for the byte that completes the
    /// sequence, after which this is false again — so callers that walk whole
    /// sequences can stop exactly at the end of the first one instead of
    /// merging the next escape into it.
    var isConsumingEscape: Bool { state != .ground }
}

/// Index just past the escape sequence that starts at `chars[start]` (which must
/// be ESC). Used by the column-walking splicers, which need whole sequences.
/// Returns the end of *one* sequence: consecutive escapes (e.g. a reset right
/// before an OSC 8 hyperlink) are kept apart, because the splicers treat each
/// sequence individually (a reset clears the style, a hyperlink open/close
/// toggles the link region).
func ansiEscapeEnd(_ chars: [Character], from start: Int) -> Int {
    var scanner = ANSIScanner()
    var i = start
    while i < chars.count {
        let wasEscaping = scanner.isConsumingEscape
        let consumed = scanner.consume(chars[i])
        if !consumed { break }
        i += 1
        if wasEscaping && !scanner.isConsumingEscape { break }
    }
    return i
}
