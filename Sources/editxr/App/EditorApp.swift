import Foundation

class EditorApp {
    private let state: EditorState
    private var stdInSource: DispatchSourceRead?
    private var arrowKeyParser = ArrowKeyParser()
    
    init(state: EditorState) {
        self.state = state
    }
    
    func start() {
        setInputMode()
        
        let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        stdInSource.setEventHandler { [weak self] in
            self?.handleInput()
        }
        stdInSource.resume()
        self.stdInSource = stdInSource
        
        signal(SIGINT, SIG_IGN)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler { [weak self] in
            self?.quit()
        }
        sigIntSource.resume()
        
        let sigWinChSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigWinChSource.setEventHandler { [weak self] in
            self?.render()
        }
        sigWinChSource.resume()
        
        render()
        dispatchMain()
    }
    
    private func setInputMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
    }
    
    private func resetInputMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
    }
    
    private func handleInput() {
        let data = FileHandle.standardInput.availableData
        guard let string = String(data: data, encoding: .utf8) else { return }
        
        for char in string {
            if arrowKeyParser.parse(character: char) {
                if let key = arrowKeyParser.arrowKey {
                    arrowKeyParser.arrowKey = nil
                    handleArrowKey(key)
                }
                continue
            }
            
            switch char {
            case Key.ctrlX:
                quit()
            case Key.ctrlS:
                state.save()
                render()
            case Key.ctrlR:
                state.toggleViewMode()
                render()
            case Key.ctrlB:
                state.toggleStatusBar()
                render()
            case Key.enter:
                if state.viewMode == .plain {
                    state.handleNewline()
                    render()
                }
            case Key.backspace:
                if state.viewMode == .plain {
                    state.handleBackspace()
                    render()
                }
            default:
                if state.viewMode == .plain && char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation || char.isSymbol {
                    state.handleCharacter(char)
                    render()
                }
            }
        }
    }
    
    private func handleArrowKey(_ key: ArrowKey) {
        switch key {
        case .up:
            state.moveUp()
        case .down:
            state.moveDown()
        case .left:
            state.moveLeft()
        case .right:
            state.moveRight()
        }
        render()
    }
    
    private func render() {
        clearScreen()
        let size = getTerminalSize()
        let output = renderEditor(width: size.width, height: size.height)
        print(output, terminator: "")
        fflush(stdout)
    }
    
    private func clearScreen() {
        print("\u{1B}[2J\u{1B}[H", terminator: "")
    }
    
    private func getTerminalSize() -> (width: Int, height: Int) {
        var size = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
            return (Int(size.ws_col), Int(size.ws_row))
        }
        return (80, 24)
    }
    
    private func renderEditor(width: Int, height: Int) -> String {
        var lines: [String] = []
        let contentHeight = state.showStatusBar ? height - 1 : height
        
        switch state.viewMode {
        case .plain:
            lines = renderPlainMode(width: width, height: contentHeight)
        case .rendered:
            lines = renderMarkdownMode(width: width, height: contentHeight)
        }
        
        while lines.count < contentHeight {
            lines.append("")
        }
        
        if state.showStatusBar {
            let statusLine = renderStatusBar(width: width)
            lines.append(statusLine)
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func renderPlainMode(width: Int, height: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        
        let startLine = max(0, doc.cursorLine - height / 2)
        let endLine = min(doc.lines.count, startLine + height)
        
        for i in startLine..<endLine {
            let line = doc.lines[i]
            if i == doc.cursorLine {
                let col = min(doc.cursorColumn, line.count)
                let before = String(line.prefix(col))
                let cursor = "\u{1B}[7m \u{1B}[0m"
                let after = String(line.dropFirst(col))
                output.append(before + cursor + after)
            } else {
                output.append(line)
            }
        }
        
        return output
    }
    
    private func renderMarkdownMode(width: Int, height: Int) -> [String] {
        var output: [String] = []
        let content = state.document.content
        let lines = content.components(separatedBy: "\n")
        
        for line in lines.prefix(height) {
            output.append(renderMarkdownLine(line))
        }
        
        return output
    }
    
    private func renderMarkdownLine(_ line: String) -> String {
        if line.hasPrefix("# ") {
            return "\u{1B}[1;33m\(line)\u{1B}[0m"
        } else if line.hasPrefix("## ") {
            return "\u{1B}[1;33m\(line)\u{1B}[0m"
        } else if line.hasPrefix("### ") {
            return "\u{1B}[33m\(line)\u{1B}[0m"
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return "\u{1B}[36m•\u{1B}[0m " + String(line.dropFirst(2))
        } else if line.hasPrefix("```") {
            return "\u{1B}[32m\(line)\u{1B}[0m"
        } else {
            var result = line
            result = highlightPattern(result, pattern: "\\*\\*(.+?)\\*\\*", prefix: "\u{1B}[1m", suffix: "\u{1B}[0m")
            result = highlightPattern(result, pattern: "\\*(.+?)\\*", prefix: "\u{1B}[3m", suffix: "\u{1B}[0m")
            result = highlightPattern(result, pattern: "`(.+?)`", prefix: "\u{1B}[32m", suffix: "\u{1B}[0m")
            return result
        }
    }
    
    private func highlightPattern(_ text: String, pattern: String, prefix: String, suffix: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        
        let matches = regex.matches(in: text, range: range).reversed()
        for match in matches {
            if let fullRange = Range(match.range, in: result),
               let captureRange = Range(match.range(at: 1), in: result) {
                let captured = String(result[captureRange])
                result.replaceSubrange(fullRange, with: prefix + captured + suffix)
            }
        }
        
        return result
    }
    
    private func renderStatusBar(width: Int) -> String {
        let doc = state.document
        let left = state.viewMode == .rendered ? "[PREVIEW]" : ""
        let right = "\(doc.wordCount) words | Ln \(doc.cursorLine + 1), Col \(doc.cursorColumn + 1)"
        let padding = width - left.count - right.count
        let spaces = String(repeating: " ", count: max(0, padding))
        return "\u{1B}[7m\(left)\(spaces)\(right)\u{1B}[0m"
    }
    
    private func quit() {
        resetInputMode()
        clearScreen()
        exit(0)
    }
}

enum ArrowKey {
    case up, down, left, right
}

class ArrowKeyParser {
    var arrowKey: ArrowKey?
    private var state: State = .initial
    
    private enum State {
        case initial
        case escape
        case bracket
    }
    
    func parse(character: Character) -> Bool {
        switch state {
        case .initial:
            if character == "\u{1B}" {
                state = .escape
                return true
            }
            return false
        case .escape:
            if character == "[" {
                state = .bracket
                return true
            }
            state = .initial
            return false
        case .bracket:
            state = .initial
            switch character {
            case "A":
                arrowKey = .up
            case "B":
                arrowKey = .down
            case "C":
                arrowKey = .right
            case "D":
                arrowKey = .left
            default:
                break
            }
            return true
        }
    }
}
