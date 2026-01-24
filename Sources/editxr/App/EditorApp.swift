import Foundation

class EditorApp {
    private let state: EditorState
    private var stdInSource: DispatchSourceRead?
    private var arrowKeyParser = ArrowKeyParser()
    private let llmService = LLMService()
    private var llmModal: LLMModal?
    
    init(state: EditorState) {
        self.state = state
        state.onSavedIndicatorChanged = { [weak self] in
            self?.render()
        }
        
        llmModal = LLMModal(llmService: llmService)
        llmModal?.onStateChanged = { [weak self] in
            self?.render()
        }
    }
    
    func start() {
        setInputMode()
        enterAlternateScreen()
        
        let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        stdInSource.setEventHandler { [weak self] in
            self?.handleInput()
        }
        stdInSource.resume()
        self.stdInSource = stdInSource
        
        signal(SIGINT, SIG_IGN)
        signal(SIGTSTP, SIG_IGN)
        
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
    
    private func enterAlternateScreen() {
        print("\u{1B}[?1049h", terminator: "")
        print("\u{1B}[?25l", terminator: "")
        print("\u{1B}[?2004h", terminator: "")
        fflush(stdout)
    }
    
    private func exitAlternateScreen() {
        print("\u{1B}[?2004l", terminator: "")
        print("\u{1B}[?25h", terminator: "")
        print("\u{1B}[?1049l", terminator: "")
        fflush(stdout)
    }
    
    private func setInputMode() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        tattr.c_iflag &= ~tcflag_t(IXON | IXOFF | ICRNL | INLCR | IGNCR)
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
        
        var needsRender = false
        
        for char in string {
            if let modal = llmModal, modal.isVisible {
                handleLLMModalInput(char)
                continue
            }
            
            if arrowKeyParser.parse(character: char) {
                if let key = arrowKeyParser.arrowKey {
                    arrowKeyParser.arrowKey = nil
                    handleArrowKey(key)
                }
                continue
            }
            
            switch char {
            case Key.ctrlQ, Key.ctrlD:
                quit()
            case Key.ctrlS:
                state.save()
                needsRender = true
            case Key.ctrlR:
                state.toggleViewMode()
                needsRender = true
            case Key.ctrlH:
                state.toggleHelp()
                needsRender = true
            case Key.ctrlL:
                state.toggleLineNumbers()
                needsRender = true
            case Key.ctrlV:
                state.paste()
                needsRender = true
            case Key.ctrlU:
                state.undo()
                needsRender = true
            case Key.ctrlG:
                state.redo()
                needsRender = true
            case Key.ctrlW:
                state.toggleWordWrap()
                needsRender = true
            case Key.ctrlSpace:
                showLLMModal()
            case Key.enter:
                state.handleNewline()
                needsRender = true
            case Key.backspace:
                state.handleBackspace()
                needsRender = true
            default:
                if state.document.hasSelection {
                    switch char {
                    case "c":
                        state.copy()
                        needsRender = true
                    case "x":
                        state.cut()
                        needsRender = true
                    default:
                        if isPrintable(char) {
                            state.handleCharacter(char)
                            needsRender = true
                        }
                    }
                } else if isPrintable(char) {
                    state.handleCharacter(char)
                    needsRender = true
                }
            }
        }
        
        if needsRender {
            render()
        }
    }
    
    private func isPrintable(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let value = scalar.value
        if value < 32 { return false }
        if value == 127 { return false }
        return true
    }
    
    private func handleLLMModalInput(_ char: Character) {
        guard let modal = llmModal else { return }
        
        if char == Key.escape {
            modal.handleEscape()
            return
        }
        
        if char == Key.enter {
            modal.handleEnter()
            return
        }
        
        if char == Key.tab && modal.handleTab() {
            if let result = modal.acceptResult() {
                applyLLMResult(result)
            }
            return
        }
        
        if char == Key.backspace {
            modal.handleBackspace()
            return
        }
        
        modal.handleCharacter(char)
    }
    
    private func showLLMModal() {
        let context: String
        if let selection = state.document.selectionRange {
            context = state.document.textInRange(selection)
        } else {
            context = state.document.currentParagraph
        }
        llmModal?.show(withContext: context)
    }
    
    private func applyLLMResult(_ result: String) {
        if state.document.hasSelection {
            state.replaceSelection(with: result)
        } else {
            state.replaceParagraph(with: result)
        }
        render()
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
        case .ctrlLeft:
            state.moveWordLeft(selecting: false)
        case .ctrlRight:
            state.moveWordRight(selecting: false)
        case .ctrlShiftLeft:
            state.moveWordLeft(selecting: true)
        case .ctrlShiftRight:
            state.moveWordRight(selecting: true)
        case .pageUp:
            state.pageUp(viewportHeight: viewportHeight)
        case .pageDown:
            state.pageDown(viewportHeight: viewportHeight)
        }
        render()
    }
    
    private func render() {
        let size = getTerminalSize()
        let output = renderEditor(width: size.width, height: size.height)
        print("\u{1B}[H\(output)\u{1B}[\(size.height);\(size.width)H", terminator: "")
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
        var reservedLines = 2
        
        let modalLines = llmModal?.render(width: width) ?? []
        if !modalLines.isEmpty {
            reservedLines += modalLines.count
        }
        
        let contentHeight = height - reservedLines
        let gutter = gutterWidth()
        let contentWidth = width - gutter
        
        state.setViewportWidth(contentWidth)
        state.adjustScroll(viewportHeight: contentHeight, viewportWidth: contentWidth)
        
        switch state.viewMode {
        case .normal:
            lines = renderNormalMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        case .raw:
            lines = renderRawMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        }
        
        while lines.count < contentHeight {
            let emptyGutter = renderGutter(lineNumber: 0, width: gutter).replacingOccurrences(of: String(0), with: " ")
            lines.append(padToWidth(emptyGutter, width: width))
        }
        
        for modalLine in modalLines {
            lines.append(padToWidth(modalLine, width: width))
        }
        
        lines.append(padToWidth(renderStatusBar(width: width), width: width))
        
        if state.showHelp {
            lines.append(padToWidth(renderHelpBar(width: width), width: width))
        } else {
            lines.append(String(repeating: " ", count: width))
        }
        
        return lines.joined(separator: "\n")
    }
    
    private func renderNormalMode(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        let selection = doc.selectionRange
        
        if state.wordWrap {
            return renderNormalModeWrapped(width: width, height: height, gutterWidth: gutterWidth)
        }
        
        let startLine = state.scrollOffset
        let endLine = min(doc.lines.count, startLine + height)
        
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
                let isHeading = spans.first.map { isHeadingSpan($0) } ?? false
                let cursorInSpan = isCursorLine ? MarkdownLineParser.spanContainingCursor(column: doc.cursorColumn, spans: spans) : nil
                
                if (isHeading && isCursorLine) || cursorInSpan != nil {
                    renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                } else {
                    renderedLine = renderLineCollapsed(line: line, spans: spans, isCursorLine: isCursorLine, cursorColumn: doc.cursorColumn)
                }
            }
            
            let gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
            let scrolled = applyHorizontalScroll(renderedLine, scrollX: state.scrollX, width: width)
            output.append(padToWidth(gutter + scrolled, width: gutterWidth + width))
        }
        
        return output
    }
    
    private func renderNormalModeWrapped(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        let selection = doc.selectionRange
        
        var visualLine = 0
        var inCodeBlock = false
        
        for i in 0..<doc.lines.count {
            let line = doc.lines[i]
            let isCodeDelimiter = MarkdownLineParser.isCodeBlockDelimiter(line)
            
            if isCodeDelimiter {
                inCodeBlock = !inCodeBlock
            }
            
            let isCursorLine = i == doc.cursorLine
            let spans = MarkdownLineParser.parse(line)
            let cursorInSpan = isCursorLine ? MarkdownLineParser.spanContainingCursor(column: doc.cursorColumn, spans: spans) : nil
            
            if let headingSpan = spans.first, isHeadingSpan(headingSpan), !isCursorLine {
                let collapsedLine = headingSpan.content
                let visualCursor = isCursorLine ? MarkdownLineParser.rawToVisual(column: doc.cursorColumn, spans: spans) : -1
                let wrappedSegments = wrapLine(collapsedLine, width: width)
                
                for (segmentIndex, wrapped) in wrappedSegments.enumerated() {
                    if visualLine >= state.scrollOffset && output.count < height {
                        let segment = wrapped.segment
                        let segmentStart = wrapped.startOffset
                        let segmentEnd = segmentStart + segment.count
                        
                        let isLastSegment = segmentIndex == wrappedSegments.count - 1
                        let cursorInSegment = isCursorLine && visualCursor >= segmentStart && (visualCursor < segmentEnd || (isLastSegment && visualCursor == segmentEnd))
                        let localCursor = cursorInSegment ? visualCursor - segmentStart : -1
                        
                        let style = headingStyle(headingSpan.kind)
                        let renderedLine = renderStyledSegment(segment: segment, style: style, cursorColumn: localCursor)
                        
                        let gutter: String
                        if segmentIndex == 0 {
                            gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
                        } else {
                            gutter = String(repeating: " ", count: gutterWidth)
                        }
                        
                        output.append(padToWidth(gutter + renderedLine, width: gutterWidth + width))
                    }
                    visualLine += 1
                }
                
                if isCursorLine && visualCursor == collapsedLine.count {
                    if let lastSeg = wrappedSegments.last, lastSeg.segment.count == width {
                        if visualLine >= state.scrollOffset && output.count < height {
                            let gutter = String(repeating: " ", count: gutterWidth)
                            let cursorLine = "\(Theme.inverse) \(Theme.reset)"
                            output.append(padToWidth(gutter + cursorLine, width: gutterWidth + width))
                        }
                        visualLine += 1
                    }
                }
            } else {
                let wrappedSegments = wrapLine(line, width: width)
                let isHeading = spans.first.map { isHeadingSpan($0) } ?? false
                
                for (segmentIndex, wrapped) in wrappedSegments.enumerated() {
                    if visualLine >= state.scrollOffset && output.count < height {
                        let segment = wrapped.segment
                        let segmentStart = wrapped.startOffset
                        let segmentEnd = segmentStart + segment.count
                        
                        let isLastSegment = segmentIndex == wrappedSegments.count - 1
                        let cursorInSegment = isCursorLine && doc.cursorColumn >= segmentStart && doc.cursorColumn < segmentEnd
                        let cursorAtSegmentEnd = isCursorLine && isLastSegment && doc.cursorColumn == segmentEnd && segment.count < width
                        let localCursor = (cursorInSegment || cursorAtSegmentEnd) ? doc.cursorColumn - segmentStart : -1
                        
                        var renderedLine: String
                        
                        if selection != nil {
                            renderedLine = renderSegmentWithSelection(segment: segment, lineIndex: i, segmentStart: segmentStart, selection: selection, doc: doc)
                        } else if inCodeBlock || isCodeDelimiter {
                            renderedLine = renderCodeBlockSegment(segment: segment, cursorColumn: localCursor)
                        } else if (isHeading && isCursorLine) || (cursorInSpan != nil && cursorInSegment) {
                            renderedLine = renderLineRaw(line: segment, cursorColumn: localCursor)
                        } else {
                            renderedLine = renderSegmentCollapsed(segment: segment, segmentStart: segmentStart, spans: spans, cursorColumn: localCursor)
                        }
                        
                        let gutter: String
                        if segmentIndex == 0 {
                            gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
                        } else {
                            gutter = String(repeating: " ", count: gutterWidth)
                        }
                        
                        output.append(padToWidth(gutter + renderedLine, width: gutterWidth + width))
                    }
                    visualLine += 1
                }
                
                if isCursorLine && doc.cursorColumn == line.count {
                    if let lastSeg = wrappedSegments.last, lastSeg.segment.count == width {
                        if visualLine >= state.scrollOffset && output.count < height {
                            let gutter = String(repeating: " ", count: gutterWidth)
                            let cursorLine = "\(Theme.inverse) \(Theme.reset)"
                            output.append(padToWidth(gutter + cursorLine, width: gutterWidth + width))
                        }
                        visualLine += 1
                    }
                }
            }
        }
        
        return output
    }
    
    private func isHeadingSpan(_ span: MarkdownSpan) -> Bool {
        switch span.kind {
        case .heading1, .heading2, .heading3: return true
        default: return false
        }
    }
    
    private func headingStyle(_ kind: SpanKind) -> String {
        switch kind {
        case .heading1: return Theme.heading1
        case .heading2: return Theme.heading2
        case .heading3: return Theme.heading3
        default: return ""
        }
    }
    
    private func renderStyledSegment(segment: String, style: String, cursorColumn: Int) -> String {
        var result = ""
        for (i, char) in segment.enumerated() {
            if i == cursorColumn {
                result += "\(Theme.inverse)\(char)\(Theme.reset)"
            } else {
                result += "\(style)\(char)\(Theme.reset)"
            }
        }
        if cursorColumn == segment.count {
            result += "\(Theme.inverse) \(Theme.reset)"
        }
        return result
    }
    
    private func renderSegmentCollapsed(segment: String, segmentStart: Int, spans: [MarkdownSpan], cursorColumn: Int) -> String {
        if spans.isEmpty {
            if cursorColumn >= 0 {
                return renderLineRaw(line: segment, cursorColumn: cursorColumn)
            }
            return segment
        }
        
        var result = ""
        
        for (i, char) in segment.enumerated() {
            let globalPos = segmentStart + i
            let isCursor = i == cursorColumn
            
            var isMarker = false
            var style = ""
            
            for span in spans {
                let inOpeningMarker = globalPos >= span.rawStart && globalPos < span.contentStart
                let inClosingMarker = globalPos >= span.contentEnd && globalPos < span.rawEnd
                
                if inOpeningMarker || inClosingMarker {
                    isMarker = true
                    break
                }
                
                if globalPos >= span.contentStart && globalPos < span.contentEnd {
                    switch span.kind {
                    case .bold: style = Theme.bold
                    case .italic: style = Theme.italic
                    case .code: style = Theme.string
                    case .heading1: style = Theme.heading1
                    case .heading2: style = Theme.heading2
                    case .heading3: style = Theme.heading3
                    }
                    break
                }
            }
            
            if isMarker {
                continue
            }
            
            if isCursor {
                result += "\(Theme.inverse)\(char)\(Theme.reset)"
            } else if !style.isEmpty {
                result += "\(style)\(char)\(Theme.reset)"
            } else {
                result += String(char)
            }
        }
        
        if cursorColumn >= segment.count && cursorColumn >= 0 {
            result += "\(Theme.inverse) \(Theme.reset)"
        }
        
        return result
    }
    
    private func wrapLine(_ line: String, width: Int) -> [(segment: String, startOffset: Int)] {
        guard width > 0 else { return [(line, 0)] }
        if line.isEmpty { return [("", 0)] }
        if line.count <= width { return [(line, 0)] }
        
        var segments: [(segment: String, startOffset: Int)] = []
        var remaining = line
        var offset = 0
        
        while !remaining.isEmpty {
            if remaining.count <= width {
                segments.append((remaining, offset))
                break
            }
            
            let chunk = String(remaining.prefix(width))
            if let lastSpace = chunk.lastIndex(of: " "), lastSpace > chunk.startIndex {
                let breakPoint = chunk.distance(from: chunk.startIndex, to: lastSpace)
                segments.append((String(remaining.prefix(breakPoint)), offset))
                offset += breakPoint + 1
                remaining = String(remaining.dropFirst(breakPoint + 1))
            } else {
                segments.append((chunk, offset))
                offset += width
                remaining = String(remaining.dropFirst(width))
            }
        }
        
        return segments.isEmpty ? [("", 0)] : segments
    }
    
    private func renderSegmentWithSelection(segment: String, lineIndex: Int, segmentStart: Int, selection: (start: CursorPosition, end: CursorPosition)?, doc: Document) -> String {
        guard let sel = selection else { return segment }
        
        let isStartLine = lineIndex == sel.start.line
        let isEndLine = lineIndex == sel.end.line
        let isBetween = lineIndex > sel.start.line && lineIndex < sel.end.line
        
        if !isStartLine && !isEndLine && !isBetween {
            return segment
        }
        
        let selStart = "\(Theme.selectionBg)\(Theme.selectionFg)"
        let selEnd = Theme.reset
        
        if isBetween {
            return selStart + segment + selEnd
        }
        
        let lineSelStart = isStartLine ? sel.start.column : 0
        let lineSelEnd = isEndLine ? sel.end.column : Int.max
        
        let localSelStart = max(0, lineSelStart - segmentStart)
        let localSelEnd = min(segment.count, lineSelEnd - segmentStart)
        
        if localSelEnd <= 0 || localSelStart >= segment.count {
            return segment
        }
        
        let before = String(segment.prefix(localSelStart))
        let selected = String(segment.dropFirst(localSelStart).prefix(localSelEnd - localSelStart))
        let after = String(segment.dropFirst(localSelEnd))
        
        return before + selStart + selected + selEnd + after
    }
    
    private func renderCodeBlockSegment(segment: String, cursorColumn: Int) -> String {
        if cursorColumn >= 0 {
            let col = min(cursorColumn, segment.count)
            let before = String(segment.prefix(col))
            let charAtCursor = col < segment.count ? String(segment[segment.index(segment.startIndex, offsetBy: col)]) : " "
            let after = col < segment.count ? String(segment.dropFirst(col + 1)) : ""
            return "\(Theme.codeBlock)\(before)\(Theme.inverse)\(charAtCursor)\(Theme.reset)\(Theme.codeBlock)\(after)\(Theme.reset)"
        }
        return "\(Theme.codeBlock)\(segment)\(Theme.reset)"
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
        let selection = doc.selectionRange
        
        if state.wordWrap {
            return renderRawModeWrapped(width: width, height: height, gutterWidth: gutterWidth)
        }
        
        let startLine = state.scrollOffset
        let endLine = min(doc.lines.count, startLine + height)
        
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
            let scrolled = applyHorizontalScroll(renderedLine, scrollX: state.scrollX, width: width)
            output.append(padToWidth(gutter + scrolled, width: gutterWidth + width))
        }
        
        return output
    }
    
    private func renderRawModeWrapped(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        let selection = doc.selectionRange
        
        var visualLine = 0
        
        for i in 0..<doc.lines.count {
            let line = doc.lines[i]
            let isCursorLine = i == doc.cursorLine
            let wrappedSegments = wrapLine(line, width: width)
            
            for (segmentIndex, wrapped) in wrappedSegments.enumerated() {
                if visualLine >= state.scrollOffset && output.count < height {
                    let segment = wrapped.segment
                    let segmentStart = wrapped.startOffset
                    let segmentEnd = segmentStart + segment.count
                    
                    let isLastSegment = segmentIndex == wrappedSegments.count - 1
                    let cursorInSegment = isCursorLine && doc.cursorColumn >= segmentStart && doc.cursorColumn < segmentEnd
                    let cursorAtSegmentEnd = isCursorLine && isLastSegment && doc.cursorColumn == segmentEnd && segment.count < width
                    let localCursor = (cursorInSegment || cursorAtSegmentEnd) ? doc.cursorColumn - segmentStart : -1
                    
                    var renderedLine: String
                    
                    if selection != nil {
                        renderedLine = renderSegmentWithSelection(segment: segment, lineIndex: i, segmentStart: segmentStart, selection: selection, doc: doc)
                    } else if cursorInSegment || cursorAtSegmentEnd {
                        renderedLine = renderLineRaw(line: segment, cursorColumn: localCursor)
                    } else {
                        renderedLine = segment
                    }
                    
                    let gutter: String
                    if segmentIndex == 0 {
                        gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
                    } else {
                        gutter = String(repeating: " ", count: gutterWidth)
                    }
                    
                    output.append(padToWidth(gutter + renderedLine, width: gutterWidth + width))
                }
                visualLine += 1
            }
            
            if isCursorLine && doc.cursorColumn == line.count {
                if let lastSeg = wrappedSegments.last, lastSeg.segment.count == width {
                    if visualLine >= state.scrollOffset && output.count < height {
                        let gutter = String(repeating: " ", count: gutterWidth)
                        let cursorLine = "\(Theme.inverse) \(Theme.reset)"
                        output.append(padToWidth(gutter + cursorLine, width: gutterWidth + width))
                    }
                    visualLine += 1
                }
            }
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
    
    private func applyHorizontalScroll(_ str: String, scrollX: Int, width: Int) -> String {
        var result = ""
        var visibleCount = 0
        var skipped = 0
        var inEscape = false
        var currentEscape = ""
        
        for char in str {
            if char == "\u{1B}" {
                inEscape = true
                currentEscape = String(char)
            } else if inEscape {
                currentEscape.append(char)
                if char.isLetter {
                    inEscape = false
                    if skipped >= scrollX {
                        result.append(currentEscape)
                    }
                    currentEscape = ""
                }
            } else {
                if skipped < scrollX {
                    skipped += 1
                } else if visibleCount < width {
                    result.append(char)
                    visibleCount += 1
                } else {
                    result.append(Theme.reset)
                    break
                }
            }
        }
        
        return result
    }
    
    private func padToWidth(_ str: String, width: Int) -> String {
        var visibleCount = 0
        var inEscape = false
        for char in str {
            if char == "\u{1B}" {
                inEscape = true
            } else if inEscape {
                if char.isLetter { inEscape = false }
            } else {
                visibleCount += 1
            }
        }
        if visibleCount >= width {
            return str
        }
        return str + String(repeating: " ", count: width - visibleCount)
    }
    
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
            ("^W", "wrap"),
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
        exitAlternateScreen()
        resetInputMode()
        exit(0)
    }
}

enum ArrowKey {
    case up, down, left, right
    case shiftUp, shiftDown, shiftLeft, shiftRight
    case ctrlLeft, ctrlRight
    case ctrlShiftLeft, ctrlShiftRight
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
            if character == "2" || character == "5" || character == "6" {
                buffer = [character]
                state = .modifierValue
                return true
            }
            state = .initial
            return false
            
        case .modifierValue:
            state = .initial
            let modifier = buffer.first ?? "0"
            switch (modifier, character) {
            // Shift+Arrow (modifier 2)
            case ("2", "A"): arrowKey = .shiftUp
            case ("2", "B"): arrowKey = .shiftDown
            case ("2", "C"): arrowKey = .shiftRight
            case ("2", "D"): arrowKey = .shiftLeft
            // Ctrl+Arrow (modifier 5)
            case ("5", "C"): arrowKey = .ctrlRight
            case ("5", "D"): arrowKey = .ctrlLeft
            // Ctrl+Shift+Arrow (modifier 6)
            case ("6", "C"): arrowKey = .ctrlShiftRight
            case ("6", "D"): arrowKey = .ctrlShiftLeft
            default: break
            }
            return true
        }
    }
}
