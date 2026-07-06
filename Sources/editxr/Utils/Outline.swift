import Foundation

/// One heading in a document outline.
struct OutlineItem: Equatable {
    let level: Int      // 1–6 (number of leading '#')
    let title: String   // heading text, '#' markers stripped (inline markup kept)
    let line: Int       // 0-based line index in the document
}

/// Pure extraction of a Markdown heading outline from document lines, used by
/// the outline panel. Skips headings inside fenced code blocks, and supports the
/// full ATX 1–6 range (independent of the renderer's 3-level styling cap).
enum Outline {

    static func items(from lines: [String]) -> [OutlineItem] {
        var items: [OutlineItem] = []
        var inFence = false
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let h = heading(trimmed) {
                items.append(OutlineItem(level: h.level, title: h.title, line: i))
            }
        }
        return items
    }

    /// ATX heading: 1–6 leading '#', a space, then non-empty text.
    private static func heading(_ t: String) -> (level: Int, title: String)? {
        let chars = Array(t)
        var level = 0
        while level < chars.count && chars[level] == "#" { level += 1 }
        guard level >= 1, level <= 6, level < chars.count, chars[level] == " " else { return nil }
        let title = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }
}
