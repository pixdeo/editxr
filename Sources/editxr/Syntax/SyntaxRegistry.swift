import Foundation

/// Maps a file (by extension) to a highlighter. Extend by adding cases here;
/// the renderer and theme stay untouched.
enum SyntaxRegistry {
    static func forFile(_ path: String) -> SyntaxHighlighter? {
        switch (path as NSString).pathExtension.lowercased() {
        case "json":
            return JSONHighlighter()
        case "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx",
             "c", "h", "cc", "cpp", "cxx", "hpp", "hh",
             "java", "kt", "kts", "go", "rs", "cs", "scala",
             "m", "mm", "php", "dart", "groovy", "gradle":
            return CLikeHighlighter(keywords: genericKeywords)
        default:
            return nil
        }
    }

    /// A broad union of C-family keywords. A generic highlighter over-matches a
    /// little across languages, which is fine for colouring.
    private static let genericKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto", "yield",
        "func", "function", "def", "fn", "fun", "lambda",
        "var", "let", "const", "val", "mut", "static", "final",
        "public", "private", "protected", "internal", "fileprivate", "open",
        "class", "struct", "enum", "interface", "protocol", "trait", "impl",
        "extends", "implements", "extension", "typealias", "typedef", "type",
        "import", "include", "package", "module", "use", "using", "from",
        "export", "require", "new", "delete", "this", "self", "super",
        "async", "await", "throw", "throws", "try", "catch", "finally",
        "defer", "guard", "in", "is", "as", "where", "with",
        "init", "deinit", "override", "convenience", "required", "lazy",
        "void", "int", "uint", "float", "double", "bool", "char", "long",
        "short", "unsigned", "signed", "auto", "string", "byte",
        "and", "or", "not", "pass", "elif", "global", "nonlocal",
    ]
}
