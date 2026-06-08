import Foundation

/// Line-based JSON highlighter: keys (strings before a colon) are `property`,
/// other strings `string`, plus numbers, `true`/`false`/`null`, and braces.
struct JSONHighlighter: SyntaxHighlighter {
    func tokens(for line: String, state: inout HLState) -> [Token] {
        let chars = Array(line)
        let n = chars.count
        var tokens: [Token] = []
        var i = 0

        func nextNonSpace(_ from: Int) -> Character? {
            var k = from
            while k < n && chars[k].isWhitespace { k += 1 }
            return k < n ? chars[k] : nil
        }

        while i < n {
            let c = chars[i]
            if c == "\"" {
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"" { i += 1; break }
                    i += 1
                }
                let kind: TokenKind = nextNonSpace(i) == ":" ? .property : .string
                tokens.append(Token(start: start, length: i - start, kind: kind))
            } else if c == "-" || c.isNumber {
                let start = i
                while i < n && (chars[i].isNumber || "-+.eE".contains(chars[i])) { i += 1 }
                tokens.append(Token(start: start, length: i - start, kind: .number))
            } else if c.isLetter {
                let start = i
                while i < n && chars[i].isLetter { i += 1 }
                let word = String(chars[start..<i])
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(Token(start: start, length: i - start, kind: .constant))
                }
            } else if "{}[],:".contains(c) {
                tokens.append(Token(start: i, length: 1, kind: .punctuation))
                i += 1
            } else {
                i += 1
            }
        }
        return tokens
    }
}
