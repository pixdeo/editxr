import Foundation

class EditorApp {
    private let state: EditorState
    private var stdInSource: DispatchSourceRead?
    private var arrowKeyParser = ArrowKeyParser()
    
    init(state: EditorState) {
        self.state = state
        state.onSavedIndicatorChanged = { [weak self] in
            self?.render()
        }
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
        
        hideCursor()
        render()
        dispatchMain()
    }
    
    private func hideCursor() {
        print("\u{1B}[?25l", terminator: "")
        fflush(stdout)
    }
    
    private func showCursor() {
        print("\u{1B}[?25h", terminator: "")
        fflush(stdout)
    }
    
    private func setInputMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON)
        tattr.c_iflag &= ~tcflag_t(IXON | IXOFF)
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
            case Key.ctrlQ:
                quit()
            case Key.ctrlS:
                state.save()
                render()
            case Key.ctrlR:
                state.toggleViewMode()
                render()
            case Key.ctrlH:
                state.toggleHelp()
                render()
            case Key.ctrlV:
                if state.viewMode == .plain {
                    state.paste()
                    render()
                }
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
                if state.viewMode == .plain {
                    if state.document.hasSelection {
                        switch char {
                        case "c":
                            state.copy()
                            render()
                        case "x":
                            state.cut()
                            render()
                        case "d":
                            state.deleteSelection()
                            render()
                        default:
                            if char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation || char.isSymbol {
                                state.handleCharacter(char)
                                render()
                            }
                        }
                    } else if char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation || char.isSymbol {
                        state.handleCharacter(char)
                        render()
                    }
                }
            }
        }
    }
    
    private func handleArrowKey(_ key: ArrowKey) {
        switch key {
        case .up:
            state.moveUp(selecting: false)
        case .down:
            state.moveDown(selecting: false)
        case .left:
            state.moveLeft(selecting: false)
        case .right:
            state.moveRight(selecting: false)
        case .shiftUp:
            state.moveUp(selecting: true)
        case .shiftDown:
            state.moveDown(selecting: true)
        case .shiftLeft:
            state.moveLeft(selecting: true)
        case .shiftRight:
            state.moveRight(selecting: true)
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
        let reservedLines = 2
        
        let contentHeight = height - reservedLines
        
        switch state.viewMode {
        case .plain:
            lines = renderPlainMode(width: width, height: contentHeight)
        case .rendered:
            lines = renderMarkdownMode(width: width, height: contentHeight)
        }
        
        while lines.count < contentHeight {
            lines.append("")
        }
        
        lines.append(renderStatusBar(width: width))
        
        if state.showHelp {
            lines.append(renderHelpBar(width: width))
        } else {
            lines.append(String(repeating: " ", count: width))
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func renderPlainMode(width: Int, height: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        
        let startLine = max(0, doc.cursorLine - height / 2)
        let endLine = min(doc.lines.count, startLine + height)
        
        let selection = doc.selectionRange
        
        for i in startLine..<endLine {
            let line = doc.lines[i]
            var renderedLine = renderLineWithSelection(line: line, lineIndex: i, selection: selection, doc: doc)
            
            if i == doc.cursorLine && !doc.hasSelection {
                let col = min(doc.cursorColumn, line.count)
                let before = String(line.prefix(col))
                let cursor = "\(Theme.cursor) \(Theme.reset)"
                let after = String(line.dropFirst(col))
                renderedLine = before + cursor + after
            }
            
            output.append(renderedLine)
        }
        
        return output
    }
    
    private func renderLineWithSelection(line: String, lineIndex: Int, selection: (start: CursorPosition, end: CursorPosition)?, doc: Document) -> String {
        guard let sel = selection else { return line }
        
        let isStartLine = lineIndex == sel.start.line
        let isEndLine = lineIndex == sel.end.line
        let isBetween = lineIndex > sel.start.line && lineIndex < sel.end.line
        
        if !isStartLine && !isEndLine && !isBetween {
            return line
        }
        
        let selStart = "\(Theme.selectionBg)\(Theme.selectionFg)"
        let selEnd = Theme.reset
        
        if isBetween {
            return selStart + line + selEnd
        }
        
        if isStartLine && isEndLine {
            let startCol = sel.start.column
            let endCol = sel.end.column
            let before = String(line.prefix(startCol))
            let selected = String(line.dropFirst(startCol).prefix(endCol - startCol))
            let after = String(line.dropFirst(endCol))
            return before + selStart + selected + selEnd + after
        }
        
        if isStartLine {
            let startCol = sel.start.column
            let before = String(line.prefix(startCol))
            let selected = String(line.dropFirst(startCol))
            return before + selStart + selected + selEnd
        }
        
        if isEndLine {
            let endCol = sel.end.column
            let selected = String(line.prefix(endCol))
            let after = String(line.dropFirst(endCol))
            return selStart + selected + selEnd + after
        }
        
        return line
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
            return "\(Theme.bold)\(Theme.keyword)\(line)\(Theme.reset)"
        } else if line.hasPrefix("## ") {
            return "\(Theme.bold)\(Theme.keyword)\(line)\(Theme.reset)"
        } else if line.hasPrefix("### ") {
            return "\(Theme.keyword)\(line)\(Theme.reset)"
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return "\(Theme.accent)•\(Theme.reset) " + String(line.dropFirst(2))
        } else if line.hasPrefix("```") {
            return "\(Theme.comment)\(line)\(Theme.reset)"
        } else {
            var result = line
            result = highlightPattern(result, pattern: "\\*\\*(.+?)\\*\\*", prefix: Theme.bold, suffix: Theme.reset)
            result = highlightPattern(result, pattern: "\\*(.+?)\\*", prefix: Theme.italic, suffix: Theme.reset)
            result = highlightPattern(result, pattern: "`(.+?)`", prefix: Theme.string, suffix: Theme.reset)
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
        
        var leftParts: [String] = []
        if state.viewMode == .rendered {
            leftParts.append("[PREVIEW]")
        }
        if state.showSavedIndicator {
            leftParts.append("Saved")
        } else if state.isDirty {
            leftParts.append("[+]")
        }
        let left = leftParts.joined(separator: " ")
        
        let right = "\(doc.wordCount) words | Ln \(doc.cursorLine + 1), Col \(doc.cursorColumn + 1)"
        let padding = width - left.count - right.count
        let spaces = String(repeating: " ", count: max(0, padding))
        return "\(Theme.statusBarBg)\(Theme.statusBarText)\(left)\(spaces)\(right)\(Theme.reset)"
    }
    
    private func renderHelpBar(width: Int) -> String {
        let shortcuts: [(key: String, desc: String)] = [
            ("^H", "help"),
            ("^Q", "quit"),
            ("^S", "save"),
            ("^R", "preview"),
            ("^V", "paste"),
            ("c", "copy"),
            ("x", "cut"),
            ("d", "delete")
        ]
        
        var parts: [String] = []
        for shortcut in shortcuts {
            parts.append("\(Theme.accent)\(shortcut.key) \(Theme.textMuted)\(shortcut.desc)\(Theme.reset)")
        }
        
        let content = parts.joined(separator: "  ")
        return content
    }
    
    private func quit() {
        showCursor()
        resetInputMode()
        clearScreen()
        exit(0)
    }
}

enum ArrowKey {
    case up, down, left, right
    case shiftUp, shiftDown, shiftLeft, shiftRight
}

class ArrowKeyParser {
    var arrowKey: ArrowKey?
    private var state: State = .initial
    private var buffer: [Character] = []
    
    private enum State {
        case initial
        case escape
        case bracket
        case modifier
        case semicolon
        case modifierValue
    }
    
    func parse(character: Character) -> Bool {
        switch state {
        case .initial:
            if character == "\u{1B}" {
                state = .escape
                buffer = []
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
            if character == "1" {
                state = .modifier
                return true
            }
            state = .initial
            switch character {
            case "A": arrowKey = .up
            case "B": arrowKey = .down
            case "C": arrowKey = .right
            case "D": arrowKey = .left
            default: break
            }
            return true
            
        case .modifier:
            if character == ";" {
                state = .semicolon
                return true
            }
            state = .initial
            return true
            
        case .semicolon:
            if character == "2" {
                state = .modifierValue
                return true
            }
            state = .initial
            return true
            
        case .modifierValue:
            state = .initial
            switch character {
            case "A": arrowKey = .shiftUp
            case "B": arrowKey = .shiftDown
            case "C": arrowKey = .shiftRight
            case "D": arrowKey = .shiftLeft
            default: break
            }
            return true
        }
    }
}
