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

struct Theme {
    static var mode: ColorMode = .detect()
    
    static var textPrimary: String { mode == .dark ? "\u{1B}[38;2;229;229;229m" : "\u{1B}[38;2;26;26;26m" }
    static var textSecondary: String { mode == .dark ? "\u{1B}[38;2;163;163;163m" : "\u{1B}[38;2;102;102;102m" }
    static var textMuted: String { mode == .dark ? "\u{1B}[38;2;115;115;115m" : "\u{1B}[38;2;138;138;138m" }
    static var accent: String { "\u{1B}[38;2;71;209;211m" }
    
    static var statusBarBg: String { mode == .dark ? "\u{1B}[48;2;38;38;38m" : "\u{1B}[48;2;240;240;240m" }
    static var statusBarText: String { mode == .dark ? "\u{1B}[38;2;163;163;163m" : "\u{1B}[38;2;100;100;100m" }
    
    static var selectionBg: String { mode == .dark ? "\u{1B}[48;2;55;90;99m" : "\u{1B}[48;2;227;248;248m" }
    static var selectionFg: String { mode == .dark ? "\u{1B}[38;2;229;229;229m" : "\u{1B}[38;2;26;26;26m" }
    
    static var gutter: String { mode == .dark ? "\u{1B}[38;2;115;115;115m" : "\u{1B}[38;2;138;138;138m" }
    
    static var heading1: String { "\u{1B}[1m\(accent)" }
    static var heading2: String { "\u{1B}[1m\(textPrimary)" }
    static var heading3: String { "\u{1B}[1m\(textSecondary)" }
    static var codeBlock: String { textMuted }
    
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let inverse = "\u{1B}[7m"
    static let underline = "\u{1B}[4m"
    static let string = "\u{1B}[38;2;102;102;102m"
}
