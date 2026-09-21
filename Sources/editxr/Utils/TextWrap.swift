import Foundation

/// Word-wrap `line` to `width` *display columns*, expanding tabs to the next
/// `tabStop`. Breaks are measured with `displayAdvance` (so wide glyphs count as
/// 2 and tabs land on their stop), but the returned `startOffset` stays a
/// Character index, because the cursor / span / segment math downstream is
/// Character-based. Prefers the last space within budget; hard-breaks a word
/// that has none, and never drops a glyph.
///
/// This is the single wrapping implementation: both the renderer and the
/// scroll/navigation math call it, so a row's on-screen height can never
/// disagree with the row count the cursor is scrolled against.
func wrapTextRows(_ line: String, width: Int, tabStop: Int) -> [(segment: String, startOffset: Int)] {
    guard width > 0 else { return [(line, 0)] }
    if line.isEmpty { return [("", 0)] }
    let chars = Array(line)
    let n = chars.count

    var total = 0
    for char in chars { total += displayAdvance(char, atColumn: total, tabStop: tabStop) }
    if total <= width { return [(line, 0)] }

    var rows: [(segment: String, startOffset: Int)] = []
    var start = 0
    while start < n {
        var w = 0
        var i = start
        var lastSpace = -1
        while i < n {
            let advance = displayAdvance(chars[i], atColumn: w, tabStop: tabStop)
            if w + advance > width { break }
            w += advance
            if chars[i] == " " { lastSpace = i }
            i += 1
        }
        if i >= n {                       // the rest fits
            rows.append((String(chars[start..<n]), start))
            break
        }
        if i == start {                   // a single glyph wider than the budget
            rows.append((String(chars[start..<start + 1]), start))
            start += 1
            continue
        }
        if lastSpace > start {            // word wrap: drop the breaking space
            rows.append((String(chars[start..<lastSpace]), start))
            start = lastSpace + 1
        } else {                          // no space: hard break, keep every glyph
            rows.append((String(chars[start..<i]), start))
            start = i
        }
    }
    return rows.isEmpty ? [("", 0)] : rows
}

/// Display width of `text` with its tabs expanded at `tabStop` (measured from
/// column 0). Used by the caret math, which must compare a segment's *display*
/// width against the wrap budget rather than its Character count.
func expandedDisplayWidth(_ text: String, tabStop: Int) -> Int {
    var width = 0
    for char in text { width += displayAdvance(char, atColumn: width, tabStop: tabStop) }
    return width
}

/// Replace every tab with the spaces that carry it to the next tab stop,
/// tracking the display column from `originColumn`. ANSI escape sequences pass
/// through untouched. This is display-only: the document keeps the tab.
func expandTabs(_ text: String, originColumn: Int, tabStop: Int) -> String {
    guard text.contains("\t") else { return text }
    var out = ""
    var column = originColumn
    var scanner = ANSIScanner()
    for char in text {
        if scanner.consume(char) {
            out.append(char)
            continue
        }
        if char == "\t" {
            let advance = displayAdvance(char, atColumn: column, tabStop: tabStop)
            out += String(repeating: " ", count: advance)
            column += advance
        } else {
            out.append(char)
            column += displayWidth(char)
        }
    }
    return out
}
