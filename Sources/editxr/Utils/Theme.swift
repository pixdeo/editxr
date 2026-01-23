import Foundation

enum Theme {
    // Base UI
    static let bg = "\u{1B}[48;2;255;255;255m"
    static let surface = "\u{1B}[48;2;245;245;245m"
    static let surfaceSoft = "\u{1B}[48;2;243;243;243m"
    static let border = "\u{1B}[38;2;200;200;200m"
    static let textPrimary = "\u{1B}[38;2;26;26;26m"
    static let textSecondary = "\u{1B}[38;2;102;102;102m"
    static let textMuted = "\u{1B}[38;2;138;138;138m"
    static let accent = "\u{1B}[38;2;71;209;211m"
    
    // Status bar
    static let statusBarBg = "\u{1B}[48;2;255;255;255m"
    static let statusBarText = "\u{1B}[38;2;138;138;138m"
    static let statusBarTextActive = "\u{1B}[38;2;26;26;26m"
    static let statusBarBorder = "\u{1B}[38;2;243;243;243m"
    static let statusBarAccent = "\u{1B}[38;2;71;209;211m"
    
    // Editor
    static let selectionBg = "\u{1B}[48;2;227;248;248m"
    static let selectionFg = "\u{1B}[38;2;26;26;26m"
    static let currentLineBg = "\u{1B}[48;2;245;245;245m"
    static let cursorUnderline = "\u{1B}[4m"
    static let gutter = "\u{1B}[38;2;138;138;138m"
    static let gutterBg = "\u{1B}[48;2;255;255;255m"
    static let gutterDivider = "\u{1B}[38;2;243;243;243m"
    
    // Syntax
    static let keyword = "\u{1B}[38;2;71;209;211m"
    static let comment = "\u{1B}[38;2;138;138;138m"
    static let string = "\u{1B}[38;2;102;102;102m"
    static let identifier = "\u{1B}[38;2;26;26;26m"
    static let punctuation = "\u{1B}[38;2;102;102;102m"
    
    // Formatting
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let inverse = "\u{1B}[7m"
    static let underline = "\u{1B}[4m"
}
