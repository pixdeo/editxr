import Foundation

enum ColorMode {
    case light
    case dark

    static func detect() -> ColorMode {
        if let bgColor = queryTerminalBackground() {
            let luminance = (bgColor.r * 299 + bgColor.g * 587 + bgColor.b * 114) / 1000
            return luminance > 128 ? .light : .dark
        }

        if let colorScheme = ProcessInfo.processInfo.environment["COLORFGBG"] {
            let parts = colorScheme.split(separator: ";")
            if let last = parts.last, let bg = Int(last) {
                return bg < 8 ? .dark : .light
            }
        }

        return .dark
    }

    private static func queryTerminalBackground() -> (r: Int, g: Int, b: Int)? {
        let tty = FileHandle(forReadingAtPath: "/dev/tty")
        let ttyOut = FileHandle(forWritingAtPath: "/dev/tty")
        guard let tty = tty, let ttyOut = ttyOut else { return nil }
        defer { try? tty.close(); try? ttyOut.close() }

        var oldTermios = termios()
        tcgetattr(tty.fileDescriptor, &oldTermios)

        var newTermios = oldTermios
        newTermios.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(tty.fileDescriptor, TCSANOW, &newTermios)
        defer { tcsetattr(tty.fileDescriptor, TCSANOW, &oldTermios) }

        let query = "\u{1B}]11;?\u{1B}\\"
        ttyOut.write(query.data(using: .utf8)!)

        var response = ""
        let deadline = Date().addingTimeInterval(0.1)

        while Date() < deadline {
            var pollFd = pollfd(fd: tty.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFd, 1, 10)
            if ready > 0 {
                if let data = try? tty.read(upToCount: 1), let char = String(data: data, encoding: .utf8) {
                    response += char
                    if response.contains("\u{1B}\\") || response.contains("\u{07}") {
                        break
                    }
                }
            }
        }

        let pattern = #"rgb:([0-9a-fA-F]{2,4})/([0-9a-fA-F]{2,4})/([0-9a-fA-F]{2,4})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)) else {
            return nil
        }

        func extractComponent(_ range: NSRange) -> Int? {
            guard let swiftRange = Range(range, in: response) else { return nil }
            let hex = String(response[swiftRange])
            guard let value = Int(hex, radix: 16) else { return nil }
            return hex.count == 4 ? value >> 8 : value
        }

        guard let r = extractComponent(match.range(at: 1)),
              let g = extractComponent(match.range(at: 2)),
              let b = extractComponent(match.range(at: 3)) else {
            return nil
        }

        return (r, g, b)
    }
}

// SGR helpers: truecolor foreground / background escape sequences.
private func fg(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[38;2;\(r);\(g);\(b)m" }
private func bg(_ r: Int, _ g: Int, _ b: Int) -> String { "\u{1B}[48;2;\(r);\(g);\(b)m" }

/// Selectable colour schemes. Kept deliberately small and minimalist —
/// each one is mode-aware (light/dark) rather than a fixed set of colours.
enum ThemeName: String, CaseIterable, Codable {
    case system    // neutral grayscale (default)
    case clay      // warm, terracotta accent
    case mono      // pure monochrome, no chroma
    case monokai   // classic Monokai (dark-oriented)

    var displayName: String {
        switch self {
        case .system:  return "System"
        case .clay:    return "Clay"
        case .mono:    return "Mono"
        case .monokai: return "Monokai"
        }
    }
}

/// A resolved set of colour tokens for one theme + mode combination.
struct ThemePalette {
    let textPrimary, textSecondary, textMuted, accent: String
    let statusBarBg, statusBarText, shadowStyle: String
    let selectionBg, selectionFg, gutter, string: String

    static func make(_ name: ThemeName, _ mode: ColorMode) -> ThemePalette {
        switch (name, mode) {
        case (.system, .dark):
            return ThemePalette(
                textPrimary: fg(229, 229, 229), textSecondary: fg(163, 163, 163),
                textMuted: fg(115, 115, 115), accent: fg(220, 220, 220),
                statusBarBg: bg(38, 38, 38), statusBarText: fg(163, 163, 163),
                shadowStyle: bg(0, 0, 0) + fg(78, 78, 78),
                selectionBg: bg(55, 90, 99), selectionFg: fg(229, 229, 229),
                gutter: fg(115, 115, 115), string: fg(102, 102, 102))
        case (.system, .light):
            return ThemePalette(
                textPrimary: fg(26, 26, 26), textSecondary: fg(102, 102, 102),
                textMuted: fg(138, 138, 138), accent: fg(0, 0, 0),
                statusBarBg: bg(240, 240, 240), statusBarText: fg(100, 100, 100),
                shadowStyle: bg(200, 200, 200) + fg(140, 140, 140),
                selectionBg: bg(227, 248, 248), selectionFg: fg(26, 26, 26),
                gutter: fg(138, 138, 138), string: fg(102, 102, 102))

        case (.clay, .dark):
            return ThemePalette(
                textPrimary: fg(235, 229, 219), textSecondary: fg(168, 160, 148),
                textMuted: fg(122, 115, 105), accent: fg(204, 120, 92),
                statusBarBg: bg(45, 42, 38), statusBarText: fg(168, 160, 148),
                shadowStyle: bg(0, 0, 0) + fg(70, 66, 60),
                selectionBg: bg(74, 66, 54), selectionFg: fg(235, 229, 219),
                gutter: fg(110, 104, 95), string: fg(150, 140, 120))
        case (.clay, .light):
            return ThemePalette(
                textPrimary: fg(41, 37, 33), textSecondary: fg(105, 98, 88),
                textMuted: fg(150, 142, 130), accent: fg(181, 95, 66),
                statusBarBg: bg(240, 236, 228), statusBarText: fg(105, 98, 88),
                shadowStyle: bg(205, 200, 190) + fg(150, 142, 130),
                selectionBg: bg(235, 222, 205), selectionFg: fg(41, 37, 33),
                gutter: fg(150, 142, 130), string: fg(130, 120, 105))

        case (.mono, .dark):
            return ThemePalette(
                textPrimary: fg(224, 224, 224), textSecondary: fg(160, 160, 160),
                textMuted: fg(112, 112, 112), accent: fg(255, 255, 255),
                statusBarBg: bg(32, 32, 32), statusBarText: fg(160, 160, 160),
                shadowStyle: bg(0, 0, 0) + fg(72, 72, 72),
                selectionBg: bg(64, 64, 64), selectionFg: fg(240, 240, 240),
                gutter: fg(112, 112, 112), string: fg(144, 144, 144))
        case (.mono, .light):
            return ThemePalette(
                textPrimary: fg(20, 20, 20), textSecondary: fg(96, 96, 96),
                textMuted: fg(140, 140, 140), accent: fg(0, 0, 0),
                statusBarBg: bg(238, 238, 238), statusBarText: fg(96, 96, 96),
                shadowStyle: bg(204, 204, 204) + fg(140, 140, 140),
                selectionBg: bg(218, 218, 218), selectionFg: fg(20, 20, 20),
                gutter: fg(140, 140, 140), string: fg(120, 120, 120))

        case (.monokai, .dark):
            // Authentic Monokai: cream text, terracotta-free magenta accent,
            // yellow strings, comment-gray muted.
            return ThemePalette(
                textPrimary: fg(248, 248, 242), textSecondary: fg(170, 170, 160),
                textMuted: fg(117, 113, 94), accent: fg(249, 38, 114),
                statusBarBg: bg(62, 61, 50), statusBarText: fg(170, 170, 160),
                shadowStyle: bg(0, 0, 0) + fg(60, 60, 55),
                selectionBg: bg(73, 72, 62), selectionFg: fg(248, 248, 242),
                gutter: fg(99, 98, 87), string: fg(230, 219, 116))
        case (.monokai, .light):
            // Monokai-flavoured, darkened for readability on a light terminal.
            return ThemePalette(
                textPrimary: fg(40, 40, 38), textSecondary: fg(95, 95, 90),
                textMuted: fg(150, 148, 140), accent: fg(192, 16, 96),
                statusBarBg: bg(236, 235, 228), statusBarText: fg(95, 95, 90),
                shadowStyle: bg(205, 204, 196) + fg(150, 148, 140),
                selectionBg: bg(228, 226, 210), selectionFg: fg(40, 40, 38),
                gutter: fg(150, 148, 140), string: fg(150, 120, 20))
        }
    }
}

struct Theme {
    static var mode: ColorMode = .detect() { didSet { refresh() } }
    static var name: ThemeName = .system { didSet { refresh() } }

    /// Active palette, cached so render-loop token access stays allocation-free.
    private(set) static var current: ThemePalette = .make(.system, Theme.mode)
    private static func refresh() { current = .make(name, mode) }

    static var textPrimary: String { current.textPrimary }
    static var textSecondary: String { current.textSecondary }
    static var textMuted: String { current.textMuted }
    static var accent: String { current.accent }

    static var statusBarBg: String { current.statusBarBg }
    static var statusBarText: String { current.statusBarText }
    // Translucent drop-shadow (Norton Commander style): underlying glyphs stay
    // visible but dimmed, over a darkened background.
    static var shadowStyle: String { current.shadowStyle }

    static var selectionBg: String { current.selectionBg }
    static var selectionFg: String { current.selectionFg }

    static var gutter: String { current.gutter }
    static var string: String { current.string }

    static var heading1: String { "\u{1B}[1m\(accent)" }
    static var heading2: String { "\u{1B}[1m\(textPrimary)" }
    static var heading3: String { "\u{1B}[1m\(textSecondary)" }
    static var codeBlock: String { textMuted }

    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let inverse = "\u{1B}[7m"
    static let underline = "\u{1B}[4m"
}
