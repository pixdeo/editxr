import Foundation

/// Turns what someone typed into the path a new note should live at. Kept out
/// of the app so the rules — vault-relative unless absolute, Markdown unless an
/// extension says otherwise — can be tested on their own.
enum NewFilePath {
    /// Resolve `input` against `root`, or nil when it names no file: `~`
    /// expands, an absolute path passes through, anything else is relative to
    /// the vault, and a bare name gets `.md`.
    static func resolve(_ input: String, root: String) -> String? {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        guard !name.isEmpty else { return nil }

        name = NSString(string: name).expandingTildeInPath
        var path = name.hasPrefix("/") ? name : root + "/" + name

        // "." and ".." point at a folder, so there is nothing to create.
        let last = (path as NSString).lastPathComponent
        guard last != "." && last != ".." else { return nil }

        // A dotfile (".gitignore") reads as extension-less but already carries
        // its own name; only a plain word gets the Markdown default.
        if (path as NSString).pathExtension.isEmpty && !last.hasPrefix(".") {
            path += ".md"
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
