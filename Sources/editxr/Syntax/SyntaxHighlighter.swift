import Foundation

/// Categories a token can fall into; mapped to colours by the theme.
enum TokenKind {
    case keyword
    case string
    case number
    case comment
    case type
    case property      // e.g. a JSON object key
    case punctuation
    case constant      // true / false / null / nil
    case plain
}

/// A coloured span on a single line, measured in Character offsets.
struct Token {
    let start: Int
    let length: Int
    let kind: TokenKind
}

/// State carried between lines (e.g. an open block comment).
struct HLState {
    var inBlockComment = false
}

/// A line-based syntax highlighter. Tokenises one line at a time, threading
/// `state` so multi-line constructs survive line boundaries.
protocol SyntaxHighlighter {
    func tokens(for line: String, state: inout HLState) -> [Token]
}
