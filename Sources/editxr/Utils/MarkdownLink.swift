import Foundation

/// Detects links in a line of Markdown for navigation and underlining. Links
/// render as raw text in the editor, so a raw (line, column) is all we need.
enum MarkdownLink {
    enum Target: Equatable {
        case path(String)   // [text](path) — a file path or URL
        case wiki(String)   // [[name]] / [[name|alias]] — resolved by name
    }

    struct Link: Equatable {
        let range: Range<Int>   // half-open character range of the whole link
        let target: Target
    }

    /// Every link on the line, left to right. Wikilinks take priority over
    /// inline `[text](url)` (they share the leading "[").
    static func links(in line: String) -> [Link] {
        let chars = Array(line)
        let n = chars.count
        var out: [Link] = []
        var i = 0
        while i < n {
            // Wikilink: [[ name (| alias)? ]]
            if chars[i] == "[", i + 1 < n, chars[i + 1] == "[",
               let close = closeWiki(chars, from: i + 2) {
                let inner = String(chars[(i + 2)..<close])
                let name = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    out.append(Link(range: i..<(close + 2), target: .wiki(trimmed)))
                }
                i = close + 2
                continue
            }
            // Inline link: [text](url)
            if chars[i] == "[", let link = inlineLink(chars, from: i) {
                if !link.url.isEmpty {
                    out.append(Link(range: i..<link.end, target: .path(link.url)))
                }
                i = link.end
                continue
            }
            i += 1
        }
        return out
    }

    /// The link target whose span covers `column`, if any.
    static func linkAt(line: String, column: Int) -> Target? {
        links(in: line).first { $0.range.contains(column) }?.target
    }

    /// Index of the first "]" of the closing "]]" at/after `from`, or nil if the
    /// wikilink isn't closed before the next "[".
    private static func closeWiki(_ chars: [Character], from: Int) -> Int? {
        var i = from
        while i + 1 < chars.count {
            if chars[i] == "]" && chars[i + 1] == "]" { return i }
            if chars[i] == "[" { return nil }
            i += 1
        }
        return nil
    }

    /// Parse `[text](url)` starting at `from` (the "["); returns the url and the
    /// index just past the ")".
    private static func inlineLink(_ chars: [Character], from: Int) -> (url: String, end: Int)? {
        guard let closeB = index(of: "]", in: chars, from: from + 1),
              closeB + 1 < chars.count, chars[closeB + 1] == "(",
              let closeP = index(of: ")", in: chars, from: closeB + 2) else { return nil }
        return (String(chars[(closeB + 2)..<closeP]), closeP + 1)
    }

    private static func index(of ch: Character, in chars: [Character], from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == ch { return i }
            i += 1
        }
        return nil
    }
}
