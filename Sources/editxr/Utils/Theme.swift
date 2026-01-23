import Foundation

enum Theme {
    static let green = "\u{1B}[38;2;78;201;176m"
    static let orange = "\u{1B}[38;2;255;165;0m"
    static let cyan = "\u{1B}[38;2;0;212;255m"
    static let yellow = "\u{1B}[38;2;220;220;170m"
    static let white = "\u{1B}[38;2;255;255;255m"
    static let gray = "\u{1B}[38;2;128;128;128m"
    static let darkGray = "\u{1B}[38;2;90;90;90m"
    static let black = "\u{1B}[38;2;30;30;30m"
    
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let italic = "\u{1B}[3m"
    static let inverse = "\u{1B}[7m"
    
    static let bgDark = "\u{1B}[48;2;30;30;30m"
    static let bgLightGray = "\u{1B}[48;2;200;200;200m"
    static let bgStatusBar = "\u{1B}[48;2;180;180;180m"
}
