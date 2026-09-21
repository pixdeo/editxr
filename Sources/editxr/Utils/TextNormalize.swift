import Foundation

/// Text arriving from disk or the clipboard can carry line separators and C0
/// control characters that a terminal interprets as cursor motion (`\r` returns
/// to column 0, `\t` jumps to a tab stop). Those make every column the editor
/// computes disagree with what the terminal actually draws, which shears the
/// command panel and hides the caret. Normalizing at the two entry points —
/// loading a file and inserting text — keeps the document free of them.
///
/// Tabs are deliberately preserved: the editor supports them natively (see the
/// display-width/`wrap` helpers), so they are safe to keep once the width math
/// accounts for them.

/// CRLF and lone CR → LF. Classic Mac and Windows line endings become the LF
/// the line model expects.
func normalizedLineEndings(_ text: String) -> String {
    guard text.contains("\r") else { return text }
    return text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

/// `normalizedLineEndings`, then drop the control characters that can't be
/// typed in the editor (see `isPrintable`). `\n` and `\t` survive: the first
/// separates lines, the second is real Markdown indentation.
func sanitizedForEditing(_ text: String) -> String {
    let normalized = normalizedLineEndings(text)
    guard normalized.unicodeScalars.contains(where: { isDroppedControl($0) }) else {
        return normalized
    }
    var out = ""
    out.reserveCapacity(normalized.count)
    for scalar in normalized.unicodeScalars {
        if !isDroppedControl(scalar) { out.unicodeScalars.append(scalar) }
    }
    return out
}

/// C0 controls and DEL, except the two the editor keeps (`\n`, `\t`).
func isDroppedControl(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "\n" || scalar == "\t" { return false }
    return scalar.value < 0x20 || scalar.value == 0x7F
}
