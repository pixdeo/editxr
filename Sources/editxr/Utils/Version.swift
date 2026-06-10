import Foundation

/// App identity + CLI help text, shared by `main` and the welcome splash.
enum AppInfo {
    static let name = "editxr"
    static let version = "1.1.2"
    static let tagline = "a minimalist Markdown editor for the terminal"

    static var helpText: String {
        """
        \(name) \(version) — \(tagline)

        Usage:
          \(name) <file>       Open or create a Markdown file
          \(name) --help       Show this help
          \(name) --version    Print the version

        Inside the editor:
          Ctrl+P    command palette / settings
          Ctrl+S    save               Ctrl+Q   quit
          Ctrl+F    find               Ctrl+G   find next
          Ctrl+Space  AI assist        Ctrl+E   export to HTML
          Ctrl+R    toggle raw view    Ctrl+W   toggle word wrap
          Ctrl+T    cycle task state   Ctrl+B   focus mode (line / word)
        """
    }
}
