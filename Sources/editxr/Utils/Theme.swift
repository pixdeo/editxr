import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

        let query = "\u{1B}]11;?\u{07}"
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

/// Whether the terminal handles 24-bit colour. iTerm2/Ghostty/WezTerm/etc set
/// COLORTERM=truecolor; Terminal.app does not, so it falls back to 256-colour.
let terminalTrueColor: Bool = {
    let env = ProcessInfo.processInfo.environment
    if let ct = env["COLORTERM"], ct.contains("truecolor") || ct.contains("24bit") { return true }
    if env["GHOSTTY_RESOURCES_DIR"] != nil || env["WEZTERM_EXECUTABLE"] != nil { return true }
    if let tp = env["TERM_PROGRAM"],
       ["iTerm.app", "ghostty", "WezTerm", "vscode", "Hyper"].contains(tp) { return true }
    return false
}()

/// Nearest xterm-256 index for an RGB colour (grayscale ramp + 6×6×6 cube).
private func ansi256(_ r: Int, _ g: Int, _ b: Int) -> Int {
    if abs(r - g) < 12 && abs(g - b) < 12 && abs(r - b) < 12 {
        if r < 8 { return 16 }
        if r > 248 { return 231 }
        return 232 + Int((Double(r - 8) / 247.0 * 24.0).rounded())
    }
    func c(_ v: Int) -> Int { Int((Double(v) / 255.0 * 5.0).rounded()) }
    return 16 + 36 * c(r) + 6 * c(g) + c(b)
}

// SGR helpers: 24-bit colour where supported, else a 256-colour approximation.
private func fg(_ r: Int, _ g: Int, _ b: Int) -> String {
    terminalTrueColor ? "\u{1B}[38;2;\(r);\(g);\(b)m" : "\u{1B}[38;5;\(ansi256(r, g, b))m"
}
private func bg(_ r: Int, _ g: Int, _ b: Int) -> String {
    terminalTrueColor ? "\u{1B}[48;2;\(r);\(g);\(b)m" : "\u{1B}[48;5;\(ansi256(r, g, b))m"
}

/// Selectable colour schemes. Kept deliberately small and minimalist —
/// each one is mode-aware (light/dark) rather than a fixed set of colours.
enum ThemeName: String, CaseIterable, Codable {
    case system      // neutral grayscale (default)
    case clay        // warm, terracotta accent
    case mono        // pure monochrome, no chroma
    case oneDark     // Atom One Dark / One Light
    case dracula     // Dracula
    case github      // GitHub (light/dark)
    case monokai     // classic Monokai
    case solarized   // Solarized (Ethan Schoonover)
    case nord        // Nord (Arctic palette)
    case gruvbox     // Gruvbox (retro warm)
    case tokyoNight  // Tokyo Night / Day
    case catppuccin  // Catppuccin (Mocha/Latte)

    var displayName: String {
        switch self {
        case .system:     return "System"
        case .clay:       return "Clay"
        case .mono:       return "Mono"
        case .oneDark:    return "One Dark Pro"
        case .dracula:    return "Dracula"
        case .github:     return "GitHub"
        case .monokai:    return "Monokai"
        case .solarized:  return "Solarized"
        case .nord:       return "Nord"
        case .gruvbox:    return "Gruvbox"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccin: return "Catppuccin"
        }
    }
}

/// Light/dark selection, independent of the palette. `auto` follows the
/// terminal's detected background; the others force a mode.
enum Appearance: String, CaseIterable, Codable {
    case auto
    case dark
    case light

    var displayName: String {
        switch self {
        case .auto:  return "Auto"
        case .dark:  return "Dark"
        case .light: return "Light"
        }
    }

    /// Resolve to a concrete mode. `auto` reuses the value detected once at
    /// launch so we never re-query the TTY while input handling is live.
    var mode: ColorMode {
        switch self {
        case .auto:  return Theme.systemDetected
        case .dark:  return .dark
        case .light: return .light
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
                textPrimary: fg(235, 229, 219), textSecondary: fg(138, 131, 121),
                textMuted: fg(122, 115, 105), accent: fg(204, 120, 92),
                statusBarBg: bg(45, 42, 38), statusBarText: fg(168, 160, 148),
                shadowStyle: bg(0, 0, 0) + fg(70, 66, 60),
                selectionBg: bg(74, 66, 54), selectionFg: fg(235, 229, 219),
                gutter: fg(110, 104, 95), string: fg(150, 140, 120))
        case (.clay, .light):
            return ThemePalette(
                textPrimary: fg(41, 37, 33), textSecondary: fg(130, 123, 112),
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

        case (.oneDark, .dark):
            // Atom One Dark.
            return ThemePalette(
                textPrimary: fg(171, 178, 191), textSecondary: fg(130, 137, 151),
                textMuted: fg(92, 99, 112), accent: fg(97, 175, 239),
                statusBarBg: bg(33, 37, 43), statusBarText: fg(130, 137, 151),
                shadowStyle: bg(0, 0, 0) + fg(60, 66, 76),
                selectionBg: bg(62, 68, 81), selectionFg: fg(171, 178, 191),
                gutter: fg(76, 82, 94), string: fg(152, 195, 121))
        case (.oneDark, .light):
            // Atom One Light.
            return ThemePalette(
                textPrimary: fg(56, 58, 66), textSecondary: fg(96, 99, 107),
                textMuted: fg(160, 161, 167), accent: fg(64, 120, 242),
                statusBarBg: bg(240, 240, 241), statusBarText: fg(96, 99, 107),
                shadowStyle: bg(205, 205, 207) + fg(150, 150, 155),
                selectionBg: bg(222, 228, 238), selectionFg: fg(56, 58, 66),
                gutter: fg(160, 161, 167), string: fg(80, 161, 79))

        case (.dracula, .dark):
            // Dracula.
            return ThemePalette(
                textPrimary: fg(248, 248, 242), textSecondary: fg(170, 172, 190),
                textMuted: fg(98, 114, 164), accent: fg(189, 147, 249),
                statusBarBg: bg(40, 42, 54), statusBarText: fg(170, 172, 190),
                shadowStyle: bg(0, 0, 0) + fg(60, 62, 74),
                selectionBg: bg(68, 71, 90), selectionFg: fg(248, 248, 242),
                gutter: fg(98, 114, 164), string: fg(241, 250, 140))
        case (.dracula, .light):
            // Alucard-style light Dracula.
            return ThemePalette(
                textPrimary: fg(31, 31, 35), textSecondary: fg(95, 95, 110),
                textMuted: fg(150, 148, 160), accent: fg(100, 74, 201),
                statusBarBg: bg(245, 243, 232), statusBarText: fg(95, 95, 110),
                shadowStyle: bg(208, 206, 196) + fg(150, 148, 160),
                selectionBg: bg(232, 228, 246), selectionFg: fg(31, 31, 35),
                gutter: fg(150, 148, 160), string: fg(155, 120, 20))

        case (.github, .dark):
            // GitHub Dark.
            return ThemePalette(
                textPrimary: fg(201, 209, 217), textSecondary: fg(139, 148, 158),
                textMuted: fg(110, 118, 129), accent: fg(88, 166, 255),
                statusBarBg: bg(22, 27, 34), statusBarText: fg(139, 148, 158),
                shadowStyle: bg(0, 0, 0) + fg(48, 54, 61),
                selectionBg: bg(28, 57, 92), selectionFg: fg(201, 209, 217),
                gutter: fg(110, 118, 129), string: fg(165, 214, 255))
        case (.github, .light):
            // GitHub Light.
            return ThemePalette(
                textPrimary: fg(36, 41, 47), textSecondary: fg(87, 96, 106),
                textMuted: fg(140, 149, 159), accent: fg(9, 105, 218),
                statusBarBg: bg(246, 248, 250), statusBarText: fg(87, 96, 106),
                shadowStyle: bg(208, 212, 217) + fg(140, 149, 159),
                selectionBg: bg(221, 235, 255), selectionFg: fg(36, 41, 47),
                gutter: fg(140, 149, 159), string: fg(10, 48, 105))

        case (.solarized, .dark):
            // Solarized Dark. Selection uses base01 so it stays visible against
            // the base02 status-bar / panel background.
            return ThemePalette(
                textPrimary: fg(131, 148, 150), textSecondary: fg(101, 123, 131),
                textMuted: fg(88, 110, 117), accent: fg(38, 139, 210),
                statusBarBg: bg(7, 54, 66), statusBarText: fg(131, 148, 150),
                shadowStyle: bg(0, 0, 0) + fg(40, 60, 66),
                selectionBg: bg(88, 110, 117), selectionFg: fg(253, 246, 227),
                gutter: fg(88, 110, 117), string: fg(42, 161, 152))
        case (.solarized, .light):
            // Solarized Light. Selection uses base1 so it stays visible against
            // the base2 status-bar / panel background.
            return ThemePalette(
                textPrimary: fg(101, 123, 131), textSecondary: fg(88, 110, 117),
                textMuted: fg(147, 161, 161), accent: fg(38, 139, 210),
                statusBarBg: bg(238, 232, 213), statusBarText: fg(101, 123, 131),
                shadowStyle: bg(213, 207, 188) + fg(147, 161, 161),
                selectionBg: bg(147, 161, 161), selectionFg: fg(0, 43, 54),
                gutter: fg(147, 161, 161), string: fg(42, 161, 152))

        case (.nord, .dark):
            // Nord (Polar Night background, Frost accent).
            return ThemePalette(
                textPrimary: fg(216, 222, 233), textSecondary: fg(159, 168, 184),
                textMuted: fg(96, 105, 124), accent: fg(136, 192, 208),
                statusBarBg: bg(46, 52, 64), statusBarText: fg(159, 168, 184),
                shadowStyle: bg(0, 0, 0) + fg(59, 66, 82),
                selectionBg: bg(67, 76, 94), selectionFg: fg(236, 239, 244),
                gutter: fg(76, 86, 106), string: fg(163, 190, 140))
        case (.nord, .light):
            // Nord (Snow Storm background).
            return ThemePalette(
                textPrimary: fg(46, 52, 64), textSecondary: fg(76, 86, 106),
                textMuted: fg(150, 158, 170), accent: fg(94, 129, 172),
                statusBarBg: bg(229, 233, 240), statusBarText: fg(76, 86, 106),
                shadowStyle: bg(200, 205, 214) + fg(150, 158, 170),
                selectionBg: bg(216, 222, 233), selectionFg: fg(46, 52, 64),
                gutter: fg(150, 158, 170), string: fg(94, 121, 80))

        case (.gruvbox, .dark):
            // Gruvbox Dark.
            return ThemePalette(
                textPrimary: fg(235, 219, 178), textSecondary: fg(168, 153, 132),
                textMuted: fg(146, 131, 116), accent: fg(254, 128, 25),
                statusBarBg: bg(60, 56, 54), statusBarText: fg(168, 153, 132),
                shadowStyle: bg(0, 0, 0) + fg(50, 48, 46),
                selectionBg: bg(80, 73, 69), selectionFg: fg(235, 219, 178),
                gutter: fg(124, 111, 100), string: fg(184, 187, 38))
        case (.gruvbox, .light):
            // Gruvbox Light.
            return ThemePalette(
                textPrimary: fg(60, 56, 54), textSecondary: fg(124, 111, 100),
                textMuted: fg(146, 131, 116), accent: fg(175, 58, 3),
                statusBarBg: bg(235, 219, 178), statusBarText: fg(124, 111, 100),
                shadowStyle: bg(208, 196, 160) + fg(146, 131, 116),
                selectionBg: bg(213, 196, 161), selectionFg: fg(60, 56, 54),
                gutter: fg(146, 131, 116), string: fg(121, 116, 14))

        case (.tokyoNight, .dark):
            // Tokyo Night.
            return ThemePalette(
                textPrimary: fg(192, 202, 245), textSecondary: fg(154, 165, 210),
                textMuted: fg(86, 95, 137), accent: fg(122, 162, 247),
                statusBarBg: bg(26, 27, 38), statusBarText: fg(154, 165, 210),
                shadowStyle: bg(0, 0, 0) + fg(40, 52, 87),
                selectionBg: bg(40, 52, 87), selectionFg: fg(192, 202, 245),
                gutter: fg(86, 95, 137), string: fg(158, 206, 106))
        case (.tokyoNight, .light):
            // Tokyo Night Day.
            return ThemePalette(
                textPrimary: fg(52, 56, 77), textSecondary: fg(101, 108, 143),
                textMuted: fg(132, 140, 181), accent: fg(45, 90, 209),
                statusBarBg: bg(225, 226, 231), statusBarText: fg(101, 108, 143),
                shadowStyle: bg(198, 199, 205) + fg(132, 140, 181),
                selectionBg: bg(208, 213, 232), selectionFg: fg(52, 56, 77),
                gutter: fg(132, 140, 181), string: fg(56, 124, 68))

        case (.catppuccin, .dark):
            // Catppuccin Mocha.
            return ThemePalette(
                textPrimary: fg(205, 214, 244), textSecondary: fg(166, 173, 200),
                textMuted: fg(108, 112, 134), accent: fg(203, 166, 247),
                statusBarBg: bg(24, 24, 37), statusBarText: fg(166, 173, 200),
                shadowStyle: bg(0, 0, 0) + fg(49, 50, 68),
                selectionBg: bg(69, 71, 90), selectionFg: fg(205, 214, 244),
                gutter: fg(108, 112, 134), string: fg(166, 227, 161))
        case (.catppuccin, .light):
            // Catppuccin Latte.
            return ThemePalette(
                textPrimary: fg(76, 79, 105), textSecondary: fg(108, 111, 133),
                textMuted: fg(156, 160, 176), accent: fg(136, 57, 239),
                statusBarBg: bg(230, 233, 239), statusBarText: fg(108, 111, 133),
                shadowStyle: bg(202, 205, 214) + fg(156, 160, 176),
                selectionBg: bg(188, 192, 204), selectionFg: fg(76, 79, 105),
                gutter: fg(156, 160, 176), string: fg(64, 160, 43))
        }
    }

    /// Editor background (the surface colour) for a theme + mode. Used to set
    /// the terminal background via OSC 11 so dark/light actually changes the
    /// canvas, not just the foreground colours.
    static func backgroundRGB(_ name: ThemeName, _ mode: ColorMode) -> (r: Int, g: Int, b: Int) {
        switch (name, mode) {
        case (.system, .dark):       return (23, 23, 23)
        case (.system, .light):      return (250, 250, 250)
        case (.clay, .dark):         return (28, 26, 24)
        case (.clay, .light):        return (250, 247, 242)
        case (.mono, .dark):         return (18, 18, 18)
        case (.mono, .light):        return (250, 250, 250)
        case (.oneDark, .dark):      return (40, 44, 52)
        case (.oneDark, .light):     return (250, 250, 250)
        case (.dracula, .dark):      return (40, 42, 54)
        case (.dracula, .light):     return (255, 251, 235)
        case (.github, .dark):       return (13, 17, 23)
        case (.github, .light):      return (255, 255, 255)
        case (.monokai, .dark):      return (39, 40, 34)
        case (.monokai, .light):     return (253, 253, 250)
        case (.solarized, .dark):    return (0, 43, 54)
        case (.solarized, .light):   return (253, 246, 227)
        case (.nord, .dark):         return (46, 52, 64)
        case (.nord, .light):        return (236, 239, 244)
        case (.gruvbox, .dark):      return (40, 40, 40)
        case (.gruvbox, .light):     return (251, 241, 199)
        case (.tokyoNight, .dark):   return (26, 27, 38)
        case (.tokyoNight, .light):  return (225, 226, 231)
        case (.catppuccin, .dark):   return (30, 30, 46)
        case (.catppuccin, .light):  return (239, 241, 245)
        }
    }

    /// Default text colour (the editor foreground) for a theme + mode. Used to
    /// set the terminal foreground via OSC 10 so plain (unstyled) text follows
    /// the theme instead of the terminal's own default colour.
    static func foregroundRGB(_ name: ThemeName, _ mode: ColorMode) -> (r: Int, g: Int, b: Int) {
        switch (name, mode) {
        case (.system, .dark):       return (229, 229, 229)
        case (.system, .light):      return (26, 26, 26)
        case (.clay, .dark):         return (235, 229, 219)
        case (.clay, .light):        return (41, 37, 33)
        case (.mono, .dark):         return (224, 224, 224)
        case (.mono, .light):        return (20, 20, 20)
        case (.oneDark, .dark):      return (171, 178, 191)
        case (.oneDark, .light):     return (56, 58, 66)
        case (.dracula, .dark):      return (248, 248, 242)
        case (.dracula, .light):     return (31, 31, 35)
        case (.github, .dark):       return (201, 209, 217)
        case (.github, .light):      return (36, 41, 47)
        case (.monokai, .dark):      return (248, 248, 242)
        case (.monokai, .light):     return (40, 40, 38)
        case (.solarized, .dark):    return (131, 148, 150)
        case (.solarized, .light):   return (101, 123, 131)
        case (.nord, .dark):         return (216, 222, 233)
        case (.nord, .light):        return (46, 52, 64)
        case (.gruvbox, .dark):      return (235, 219, 178)
        case (.gruvbox, .light):     return (60, 56, 54)
        case (.tokyoNight, .dark):   return (192, 202, 245)
        case (.tokyoNight, .light):  return (52, 56, 77)
        case (.catppuccin, .dark):   return (205, 214, 244)
        case (.catppuccin, .light):  return (76, 79, 105)
        }
    }

    /// OSC 10 + OSC 11 sequence: set the terminal foreground and background to
    /// this theme's text/surface colours. BEL-terminated (widely supported); only
    /// emitted on true-colour terminals. Empty string when unsupported.
    static func backgroundOSC(_ name: ThemeName, _ mode: ColorMode) -> String {
        guard terminalTrueColor else { return "" }
        let (br, bg, bb) = backgroundRGB(name, mode)
        let (fr, fg, fb) = foregroundRGB(name, mode)
        return String(format: "\u{1B}]10;rgb:%02x/%02x/%02x\u{07}\u{1B}]11;rgb:%02x/%02x/%02x\u{07}",
                      fr, fg, fb, br, bg, bb)
    }
}

struct Theme {
    /// Background detected once at launch; `Appearance.auto` reuses this.
    static let systemDetected: ColorMode = .detect()
    static var mode: ColorMode = systemDetected { didSet { refresh() } }
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

    // Diff colours for inline LLM-edit review. Universal-ish muted green/red,
    // so they read the same across palettes (only mode varies).
    static var diffAdd: String { mode == .dark ? fg(126, 178, 109) : fg(70, 136, 58) }
    static var diffDel: String { mode == .dark ? fg(200, 110, 110) : fg(176, 64, 64) }

    /// Colour for a syntax token, reusing palette tokens plus two mode-aware
    /// hues (number, type) so it stays coherent across themes.
    static func syntaxColor(_ kind: TokenKind) -> String {
        switch kind {
        case .keyword, .constant, .property: return accent
        case .string:                        return string
        case .comment:                       return textMuted
        case .punctuation:                   return textSecondary
        case .number:                        return mode == .dark ? fg(150, 190, 190) : fg(40, 120, 130)
        case .type:                          return mode == .dark ? fg(206, 184, 130) : fg(150, 110, 40)
        case .plain:                         return textPrimary
        }
    }

    static var heading1: String { "\u{1B}[1m\(accent)" }
    static var heading2: String { "\u{1B}[1m\(textPrimary)" }
    static var heading3: String { "\u{1B}[1m\(textSecondary)" }
    static var codeBlock: String { textSecondary }

    /// Subtle surface behind fenced code blocks: a small offset from the editor
    /// background (lighter on dark themes, darker on light ones).
    static var codeBlockBg: String {
        let (r, g, b) = ThemePalette.backgroundRGB(name, mode)
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        let d = lum < 128 ? 18 : -12
        func c(_ v: Int) -> Int { max(0, min(255, v + d)) }
        return bg(c(r), c(g), c(b))
    }

    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let inverse = "\u{1B}[7m"
    static let underline = "\u{1B}[4m"
}
