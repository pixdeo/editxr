import Foundation

/// Minimal, dependency-free Markdown → HTML converter. Supports the same
/// constructs the editor renders: frontmatter, headings, bold/italic/code,
/// links, lists, task lists, tables, blockquotes, code fences, and paragraphs.
enum MarkdownHTML {

    /// A full HTML document with a small, clean stylesheet.
    static func render(_ lines: [String]) -> String {
        let (title, body) = renderBody(lines)
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { max-width: 44rem; margin: 3rem auto; padding: 0 1.25rem;
               font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
               color: #1a1a1a; background: #fff; }
        @media (prefers-color-scheme: dark) { body { color: #e5e5e5; background: #1a1a1a; } }
        h1,h2,h3,h4 { line-height: 1.25; margin: 1.8em 0 .6em; font-weight: 650; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; }
        p,ul,ol,blockquote,table,pre { margin: 0 0 1em; }
        a { color: #c2410c; }
        code { font: .9em/1 ui-monospace, SFMono-Regular, Menlo, monospace;
               background: rgba(127,127,127,.15); padding: .15em .35em; border-radius: 4px; }
        pre { background: rgba(127,127,127,.1); padding: 1em; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid rgba(127,127,127,.4); margin-left: 0;
                     padding-left: 1em; color: rgba(127,127,127,1); }
        table { border-collapse: collapse; }
        th,td { border: 1px solid rgba(127,127,127,.3); padding: .4em .7em; text-align: left; }
        ul.tasks { list-style: none; padding-left: .2em; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Block level

    private static func renderBody(_ lines: [String]) -> (title: String, html: String) {
        var html = ""
        var title = "Document"
        var i = 0

        // Frontmatter
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var j = 1
            while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces) != "---" {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.lowercased().hasPrefix("title:") {
                    title = String(t.dropFirst("title:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
                j += 1
            }
            i = min(j + 1, lines.count)
        }

        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.isEmpty { i += 1; continue }

            // Code fence
            if t.hasPrefix("```") {
                var code: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }   // closing fence
                html += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            // Heading
            if let (level, content) = heading(t) {
                html += "<h\(level)>\(inline(content))</h\(level)>\n"
                i += 1
                continue
            }

            // Thematic break
            if isThematicBreak(t) {
                html += "<hr>\n"
                i += 1
                continue
            }

            // Table
            if isTableRow(t), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                var rows: [String] = []
                while i < lines.count && isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(lines[i]); i += 1
                }
                html += renderTable(rows)
                continue
            }

            // Blockquote
            if t.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    quoted.append(q.trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                html += "<blockquote>\(inline(quoted.joined(separator: " ")))</blockquote>\n"
                continue
            }

            // List (bullets and tasks)
            if listItem(t) != nil {
                var anyTask = false
                var items = ""
                while i < lines.count, let item = listItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    if let checked = item.checked {
                        anyTask = true
                        let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                        items += "<li>\(box)\(inline(item.content))</li>\n"
                    } else {
                        items += "<li>\(inline(item.content))</li>\n"
                    }
                    i += 1
                }
                html += "<ul\(anyTask ? " class=\"tasks\"" : "")>\n\(items)</ul>\n"
                continue
            }

            // Paragraph
            var para: [String] = []
            while i < lines.count {
                let pt = lines[i].trimmingCharacters(in: .whitespaces)
                if pt.isEmpty || startsBlock(pt, next: i + 1 < lines.count ? lines[i + 1] : nil) { break }
                para.append(pt); i += 1
            }
            if !para.isEmpty {
                html += "<p>\(inline(para.joined(separator: " ")))</p>\n"
            }
        }
        return (title, html)
    }

    /// Would `line` start a non-paragraph block? Used to end a paragraph.
    private static func startsBlock(_ t: String, next: String?) -> Bool {
        if t.hasPrefix("#") && heading(t) != nil { return true }
        if t.hasPrefix("```") || t.hasPrefix(">") { return true }
        if isThematicBreak(t) { return true }
        if listItem(t) != nil { return true }
        if isTableRow(t), let n = next, isTableSeparator(n) { return true }
        return false
    }

    private static func heading(_ t: String) -> (Int, String)? {
        var level = 0
        for c in t { if c == "#" { level += 1 } else { break } }
        guard level >= 1 && level <= 6 else { return nil }
        let rest = String(t.dropFirst(level))
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// A thematic break: only `-`, `*`, or `_` (3+ of the same char, spaces ok).
    private static func isThematicBreak(_ t: String) -> Bool {
        let stripped = t.filter { !$0.isWhitespace }
        guard stripped.count >= 3, let first = stripped.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func listItem(_ t: String) -> (checked: Bool?, content: String)? {
        guard let first = t.first, "-*+".contains(first), t.dropFirst().first == " " else { return nil }
        var content = String(t.dropFirst(2))
        let lower = content.lowercased()
        if lower.hasPrefix("[ ] ") { return (false, String(content.dropFirst(4))) }
        if lower.hasPrefix("[*] ") { return (false, String(content.dropFirst(4))) }
        if lower.hasPrefix("[x] ") { return (true, String(content.dropFirst(4))) }
        content = content.trimmingCharacters(in: .whitespaces)
        return (nil, content)
    }

    private static func isTableRow(_ t: String) -> Bool { t.contains("|") && !t.isEmpty }

    private static func isTableSeparator(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") && t.contains("|") else { return false }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|")
        return !cells.isEmpty && cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func renderTable(_ rows: [String]) -> String {
        guard rows.count >= 2 else { return "" }
        var html = "<table>\n<thead><tr>"
        for cell in tableCells(rows[0]) { html += "<th>\(inline(cell))</th>" }
        html += "</tr></thead>\n<tbody>\n"
        for row in rows.dropFirst(2) {
            html += "<tr>"
            for cell in tableCells(row) { html += "<td>\(inline(cell))</td>" }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        return html
    }

    // MARK: - Inline

    private static func inline(_ s: String) -> String {
        let chars = Array(s)
        let n = chars.count
        var out = ""
        var i = 0
        while i < n {
            let c = chars[i]

            if c == "`" {
                if let close = firstIndex(of: "`", in: chars, from: i + 1) {
                    out += "<code>\(escape(String(chars[i + 1..<close])))</code>"
                    i = close + 1
                    continue
                }
            }
            if c == "*" && i + 1 < n && chars[i + 1] == "*" {
                if let close = firstDouble(of: "*", in: chars, from: i + 2) {
                    out += "<strong>\(inline(String(chars[i + 2..<close])))</strong>"
                    i = close + 2
                    continue
                }
            }
            if c == "*" {
                if let close = firstSingle(of: "*", in: chars, from: i + 1) {
                    out += "<em>\(inline(String(chars[i + 1..<close])))</em>"
                    i = close + 1
                    continue
                }
            }
            if c == "[" {
                if let link = parseLink(chars, from: i) {
                    out += "<a href=\"\(escapeAttr(link.url))\">\(inline(link.text))</a>"
                    i = link.end
                    continue
                }
            }
            out += escape(String(c))
            i += 1
        }
        return out
    }

    private static func firstIndex(of ch: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count { if chars[i] == ch { return i }; i += 1 }
        return nil
    }

    private static func firstSingle(of ch: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == ch && !(i + 1 < chars.count && chars[i + 1] == ch)
                && !(i > from && chars[i - 1] == ch) { return i }
            i += 1
        }
        return nil
    }

    private static func firstDouble(of ch: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i + 1 < chars.count { if chars[i] == ch && chars[i + 1] == ch { return i }; i += 1 }
        return nil
    }

    private static func parseLink(_ chars: [Character], from: Int) -> (text: String, url: String, end: Int)? {
        guard let closeBracket = firstIndex(of: "]", in: chars, from: from + 1),
              closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
              let closeParen = firstIndex(of: ")", in: chars, from: closeBracket + 2) else { return nil }
        let text = String(chars[from + 1..<closeBracket])
        let url = String(chars[closeBracket + 2..<closeParen])
        return (text, url, closeParen + 1)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttr(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
