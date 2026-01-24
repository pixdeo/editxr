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
            case Key.ctrlL:
                state.toggleLineNumbers()
                render()
            case Key.ctrlV:
                state.paste()
                render()
            case Key.ctrlU:
                state.undo()
                render()
            case Key.ctrlG:
                state.redo()
                render()
            case Key.enter:
                state.handleNewline()
                render()
            case Key.backspace:
                state.handleBackspace()
                render()
            default:
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
    
    private func handleArrowKey(_ key: ArrowKey) {
        let size = getTerminalSize()
        let viewportHeight = size.height - 2
        
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
        case .pageUp:
            state.pageUp(viewportHeight: viewportHeight)
        case .pageDown:
            state.pageDown(viewportHeight: viewportHeight)
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
    
    private func gutterWidth() -> Int {
        if state.showLineNumbers {
            let maxLineNum = state.document.lines.count
            return String(maxLineNum).count + 1
        }
        return 1
    }
    
    private func renderGutter(lineNumber: Int, width: Int) -> String {
        if state.showLineNumbers {
            let numStr = String(lineNumber)
            let padding = String(repeating: " ", count: width - numStr.count - 1)
            return "\(Theme.gutter)\(padding)\(numStr) \(Theme.reset)"
        }
        return " "
    }
    
    private func renderEditor(width: Int, height: Int) -> String {
        var lines: [String] = []
        let reservedLines = 2
        
        let contentHeight = height - reservedLines
        let gutter = gutterWidth()
        let contentWidth = width - gutter
        
        state.adjustScroll(viewportHeight: contentHeight)
        
        switch state.viewMode {
        case .normal:
            lines = renderNormalMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        case .raw:
            lines = renderRawMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        }
        
        while lines.count < contentHeight {
            lines.append(renderGutter(lineNumber: 0, width: gutter).replacingOccurrences(of: String(0), with: " "))
        }
        
        lines.append(renderStatusBar(width: width))
        
        if state.showHelp {
            lines.append(renderHelpBar(width: width))
        } else {
            lines.append(String(repeating: " ", count: width))
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func renderNormalMode(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        
        let startLine = state.scrollOffset
        let endLine = min(doc.lines.count, startLine + height)
        
        let selection = doc.selectionRange
        
        var inCodeBlock = isInsideCodeBlock(beforeLine: startLine, doc: doc)
        
        for i in startLine..<endLine {
            let line = doc.lines[i]
            let isCodeDelimiter = MarkdownLineParser.isCodeBlockDelimiter(line)
            
            if isCodeDelimiter {
                inCodeBlock = !inCodeBlock
            }
            
            let isCursorLine = i == doc.cursorLine
            var renderedLine: String
            
            if selection != nil {
                renderedLine = renderLineWithSelection(line: line, lineIndex: i, selection: selection, doc: doc)
            } else if inCodeBlock || isCodeDelimiter {
                renderedLine = renderCodeBlockLine(line: line, isCursorLine: isCursorLine, cursorColumn: doc.cursorColumn)
            } else {
                let spans = MarkdownLineParser.parse(line)
                let cursorInSpan = isCursorLine ? MarkdownLineParser.spanContainingCursor(column: doc.cursorColumn, spans: spans) : nil
                
                if cursorInSpan != nil {
                    renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                } else {
                    renderedLine = renderLineCollapsed(line: line, spans: spans, isCursorLine: isCursorLine, cursorColumn: doc.cursorColumn)
                }
            }
            
            let gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
            let truncated = truncateToWidth(renderedLine, width: width)
            output.append(gutter + truncated)
        }
        
        return output
    }
    
    private func isInsideCodeBlock(beforeLine: Int, doc: Document) -> Bool {
        var inside = false
        for i in 0..<beforeLine {
            if MarkdownLineParser.isCodeBlockDelimiter(doc.lines[i]) {
                inside = !inside
            }
        }
        return inside
    }
    
    private func renderCodeBlockLine(line: String, isCursorLine: Bool, cursorColumn: Int) -> String {
        if isCursorLine {
            let col = min(cursorColumn, line.count)
            let before = String(line.prefix(col))
            let charAtCursor = col < line.count ? String(line[line.index(line.startIndex, offsetBy: col)]) : " "
            let after = col < line.count ? String(line.dropFirst(col + 1)) : ""
            return "\(Theme.codeBlock)\(before)\(Theme.inverse)\(charAtCursor)\(Theme.reset)\(Theme.codeBlock)\(after)\(Theme.reset)"
        }
        return "\(Theme.codeBlock)\(line)\(Theme.reset)"
    }
    
    private func renderRawMode(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        
        let startLine = state.scrollOffset
        let endLine = min(doc.lines.count, startLine + height)
        
        let selection = doc.selectionRange
        
        for i in startLine..<endLine {
            let line = doc.lines[i]
            let isCursorLine = i == doc.cursorLine
            
            var renderedLine: String
            
            if selection != nil {
                renderedLine = renderLineWithSelection(line: line, lineIndex: i, selection: selection, doc: doc)
            } else if isCursorLine {
                renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
            } else {
                renderedLine = line
            }
            
            let gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
            let truncated = truncateToWidth(renderedLine, width: width)
            output.append(gutter + truncated)
        }
        
        return output
    }
    
    private func renderLineRaw(line: String, cursorColumn: Int) -> String {
        let col = min(cursorColumn, line.count)
        let before = String(line.prefix(col))
        let charAtCursor = col < line.count ? String(line[line.index(line.startIndex, offsetBy: col)]) : " "
        let cursor = "\(Theme.inverse)\(charAtCursor)\(Theme.reset)"
        let after = col < line.count ? String(line.dropFirst(col + 1)) : ""
        return before + cursor + after
    }
    
    private func renderLineCollapsed(line: String, spans: [MarkdownSpan], isCursorLine: Bool, cursorColumn: Int) -> String {
        if spans.isEmpty {
            if isCursorLine {
                return renderLineRaw(line: line, cursorColumn: cursorColumn)
            }
            return line
        }
        
        var result = ""
        var lastEnd = 0
        let chars = Array(line)
        
        let visualCursorCol = isCursorLine ? MarkdownLineParser.rawToVisual(column: cursorColumn, spans: spans) : -1
        var visualPos = 0
        
        for span in spans.sorted(by: { $0.rawStart < $1.rawStart }) {
            if span.rawStart > lastEnd {
                let plainText = String(chars[lastEnd..<span.rawStart])
                result += renderWithCursor(text: plainText, style: "", visualPos: &visualPos, cursorCol: visualCursorCol)
            }
            
            let style: String
            switch span.kind {
            case .bold: style = Theme.bold
            case .italic: style = Theme.italic
            case .code: style = Theme.string
            case .heading1: style = Theme.heading1
            case .heading2: style = Theme.heading2
            case .heading3: style = Theme.heading3
            }
            
            result += renderWithCursor(text: span.content, style: style, visualPos: &visualPos, cursorCol: visualCursorCol)
            lastEnd = span.rawEnd
        }
        
        if lastEnd < chars.count {
            let remaining = String(chars[lastEnd...])
            result += renderWithCursor(text: remaining, style: "", visualPos: &visualPos, cursorCol: visualCursorCol)
        }
        
        if isCursorLine && visualCursorCol >= visualPos {
            result += "\(Theme.inverse) \(Theme.reset)"
        }
        
        return result
    }
    
    private func renderWithCursor(text: String, style: String, visualPos: inout Int, cursorCol: Int) -> String {
        var result = ""
        for char in text {
            if visualPos == cursorCol {
                result += "\(Theme.inverse)\(char)\(Theme.reset)"
            } else if !style.isEmpty {
                result += "\(style)\(char)\(Theme.reset)"
            } else {
                result += String(char)
            }
            visualPos += 1
        }
        return result
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
    
    /// Truncate a string with ANSI codes to a visible width
    private func truncateToWidth(_ str: String, width: Int) -> String {
        var result = ""
        var visibleCount = 0
        var inEscape = false
        
        for char in str {
            if char == "\u{1B}" {
                inEscape = true
                result.append(char)
            } else if inEscape {
                result.append(char)
                if char.isLetter {
                    inEscape = false
                }
            } else {
                if visibleCount < width {
                    result.append(char)
                    visibleCount += 1
                } else {
                    // End any active styling and stop
                    result.append(Theme.reset)
                    break
                }
            }
        }
        
        return result
    }
    
    private func renderStatusBar(width: Int) -> String {
        let doc = state.document
        
        var leftParts: [String] = []
        if state.viewMode == .raw {
            leftParts.append("[RAW]")
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
            ("^R", "raw"),
            ("^L", "lines"),
            ("^U", "undo"),
            ("^G", "redo")
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
    case pageUp, pageDown
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
        case pageKey
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
            if character == "5" || character == "6" {
                buffer = [character]
                state = .pageKey
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
            
        case .pageKey:
            state = .initial
            if character == "~" && !buffer.isEmpty {
                if buffer[0] == "5" {
                    arrowKey = .pageUp
                } else if buffer[0] == "6" {
                    arrowKey = .pageDown
                }
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
