import Foundation

/// A generic highlighter for C-family languages (Swift, JS/TS, C/C++, Java, Go,
/// Rust, …). Handles line/block comments, strings, numbers, keywords, and
/// treats Capitalized identifiers as types. Keywords are passed in so the same
/// engine serves many languages.
struct CLikeHighlighter: SyntaxHighlighter {
    let keywords: Set<String>

    func tokens(for line: String, state: inout HLState) -> [Token] {
        let chars = Array(line)
        let n = chars.count
        var tokens: [Token] = []
        var i = 0

        // Finish an open block comment from a previous line.
        if state.inBlockComment {
            let start = i
            while i < n {
                if i + 1 < n && chars[i] == "*" && chars[i + 1] == "/" {
                    i += 2
                    state.inBlockComment = false
                    break
                }
                i += 1
            }
            tokens.append(Token(start: start, length: i - start, kind: .comment))
        }

        while i < n {
            let c = chars[i]

            if c == "/" && i + 1 < n && chars[i + 1] == "/" {
                tokens.append(Token(start: i, length: n - i, kind: .comment))
                break
            }
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                let start = i
                i += 2
                var closed = false
                while i < n {
                    if i + 1 < n && chars[i] == "*" && chars[i + 1] == "/" { i += 2; closed = true; break }
                    i += 1
                }
                if !closed { state.inBlockComment = true }
                tokens.append(Token(start: start, length: i - start, kind: .comment))
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    i += 1
                }
                tokens.append(Token(start: start, length: i - start, kind: .string))
                continue
            }
            if c.isNumber {
                let start = i
                while i < n && (chars[i].isNumber || chars[i] == "." || chars[i] == "_" ||
                                "xXbBoOeEaAcCdDfF".contains(chars[i])) { i += 1 }
                tokens.append(Token(start: start, length: i - start, kind: .number))
                continue
            }
            if c.isLetter || c == "_" {
                let start = i
                while i < n && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") { i += 1 }
                let word = String(chars[start..<i])
                if keywords.contains(word) {
                    tokens.append(Token(start: start, length: i - start, kind: .keyword))
                } else if word.first?.isUppercase == true {
                    tokens.append(Token(start: start, length: i - start, kind: .type))
                }
                continue
            }
            if "{}()[];,.:?&|!<>=+-*/%^~".contains(c) {
                tokens.append(Token(start: i, length: 1, kind: .punctuation))
            }
            i += 1
        }
        return tokens
    }
}
