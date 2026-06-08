import Foundation

private enum SegmentRenderMode {
    case raw
    case collapsed([MarkdownSpan])
    case codeBlock
    case selection
    case heading(String)
    case list(ListRender)
    case quote(QuoteRender)
    case frontmatterDelimiter
    case frontmatterProp(key: String, value: String)
}

private enum TodoState {
    case unchecked
    case checked
    case partial
}

private enum ListLineKind {
    case bullet
    case todo(TodoState)
}

private struct ListLine {
    let indent: String
    let kind: ListLineKind
    let content: String
}

private struct ListRender {
    let prefix: String
    let prefixStyle: String
    let contentSpans: [MarkdownSpan]
}

private struct QuoteLine {
    let indent: String
    let content: String
}

private struct QuoteRender {
    let prefix: String
    let prefixStyle: String
    let contentSpans: [MarkdownSpan]
}

class EditorApp {
    private let state: EditorState
    private var stdInSource: DispatchSourceRead?
    private var arrowKeyParser = ArrowKeyParser()
    private let llmService = LLMService()
    private var llmModal: LLMModal?
    private let openAIOAuth = OpenAIOAuth()
    private var commandPanel: CommandPanel?
    /// Whole-line range the next LLM result should review against, captured
    /// when the modal opens (selection or current block).
    private var reviewRange: (startLine: Int, endLine: Int)?
    /// Drives re-renders so the LLM spinner animates while processing.
    private var spinnerTimer: DispatchSourceTimer?

    init(state: EditorState) {
        self.state = state
        state.onSavedIndicatorChanged = { [weak self] in
            self?.render()
        }
        
        llmModal = LLMModal(llmService: llmService)
        llmModal?.onStateChanged = { [weak self] in
            self?.updateSpinnerTimer()
            self?.render()
        }
        llmModal?.onResultReady = { [weak self] text in
            self?.enterReview(with: text)
        }

        syncLLMService()

        commandPanel = CommandPanel()
        commandPanel?.onStateChanged = { [weak self] in
            self?.render()
        }
    }

    private func buildCommands() -> [PaletteCommand] {
        var cmds: [PaletteCommand] = [
            PaletteCommand(title: "Save", shortcut: "^S") { [weak self] in self?.state.save() },
            PaletteCommand(title: "Toggle raw view", shortcut: "^R") { [weak self] in self?.state.toggleViewMode() },
            PaletteCommand(title: "Toggle word wrap", shortcut: "^W") { [weak self] in self?.state.toggleWordWrap() },
            PaletteCommand(title: "Toggle line numbers", shortcut: "^L") { [weak self] in self?.state.toggleLineNumbers() },
            PaletteCommand(title: "Toggle help bar", shortcut: "^/") { [weak self] in self?.state.toggleHelp() },
            PaletteCommand(title: "Toggle scroll past end", shortcut: "") { [weak self] in self?.state.toggleScrollPastEnd() },
            PaletteCommand(title: "Toggle full table borders", shortcut: "") { [weak self] in self?.state.toggleFullTable() },
            PaletteCommand(title: "Set left margin", shortcut: "\(state.leftMargin)") { [weak self] in
                guard let self = self else { return }
                self.commandPanel?.beginInput(prompt: "Left margin (columns, 0–8)", value: "\(self.state.leftMargin)", isSecret: false) { [weak self] value in
                    if let n = Int(value.trimmingCharacters(in: .whitespaces)) { self?.state.setLeftMargin(n) }
                }
            },
        ]
        for theme in ThemeName.allCases {
            let active = state.themeName == theme
            cmds.append(PaletteCommand(title: "Theme: \(theme.displayName)", shortcut: active ? "current" : "") { [weak self] in
                self?.state.setTheme(theme)
            })
        }
        for appearance in Appearance.allCases {
            let active = state.appearance == appearance
            cmds.append(PaletteCommand(title: "Appearance: \(appearance.displayName)", shortcut: active ? "current" : "") { [weak self] in
                self?.state.setAppearance(appearance)
            })
        }
        cmds += [
            PaletteCommand(title: "Undo", shortcut: "^U") { [weak self] in self?.state.undo() },
            PaletteCommand(title: "Redo", shortcut: "^G") { [weak self] in self?.state.redo() },
            PaletteCommand(title: "Go to top", shortcut: "Home") { [weak self] in self?.state.goToTop() },
            PaletteCommand(title: "Go to bottom", shortcut: "End") { [weak self] in self?.state.goToBottom() },
            PaletteCommand(title: "Page up", shortcut: "PgUp") { [weak self] in
                guard let self = self else { return }
                self.state.pageUp(viewportHeight: self.getTerminalSize().height - 3)
            },
            PaletteCommand(title: "Page down", shortcut: "PgDn") { [weak self] in
                guard let self = self else { return }
                self.state.pageDown(viewportHeight: self.getTerminalSize().height - 3)
            },
            PaletteCommand(title: "AI assist", shortcut: "^Space") { [weak self] in self?.showLLMModal() },
        ]
        cmds.append(PaletteCommand(title: "LLM settings", shortcut: "→") { [weak self] in
            self?.pushLLMSettings()
        })
        cmds.append(PaletteCommand(title: "Quit", shortcut: "^Q") { [weak self] in self?.quit() })
        return cmds
    }

    // MARK: - LLM settings menus

    private func selectProvider(_ provider: LLMProvider) {
        state.setLLMProvider(provider)
        syncLLMService()
        commandPanel?.hide()
    }

    private func pushLLMSettings() {
        var cmds: [PaletteCommand] = []
        func mark(_ p: LLMProvider) -> String { state.llmProvider == p ? "current" : "" }

        cmds.append(PaletteCommand(title: "Provider: LM Studio", shortcut: mark(.lmStudio)) { [weak self] in
            self?.selectProvider(.lmStudio)
        })
        if state.openAIIsSignedIn {
            cmds.append(PaletteCommand(title: "Provider: OpenAI", shortcut: mark(.openaiOAuth)) { [weak self] in
                self?.selectProvider(.openaiOAuth)
            })
        } else {
            cmds.append(PaletteCommand(title: "Sign in to OpenAI", shortcut: "") { [weak self] in
                self?.startOpenAIOAuth()
            })
        }
        cmds.append(PaletteCommand(title: "OpenRouter", shortcut: "→") { [weak self] in
            self?.pushOpenRouterSettings()
        })
        cmds.append(PaletteCommand(title: "Provider: Mock (offline)", shortcut: mark(.mock)) { [weak self] in
            self?.selectProvider(.mock)
        })
        commandPanel?.push(title: "LLM Settings", commands: cmds)
    }

    private func pushOpenRouterSettings() {
        let keyLabel = (state.openRouterKey?.isEmpty == false) ? "set" : "not set"
        let modelLabel = (state.openRouterModel?.isEmpty == false) ? state.openRouterModel! : "default"
        let cmds: [PaletteCommand] = [
            PaletteCommand(title: "Set API key", shortcut: keyLabel) { [weak self] in
                guard let self = self else { return }
                self.commandPanel?.beginInput(prompt: "OpenRouter API key", value: self.state.openRouterKey ?? "", isSecret: true) { [weak self] key in
                    self?.state.setOpenRouterKey(key)
                    self?.syncLLMService()
                }
            },
            PaletteCommand(title: "Set model", shortcut: modelLabel) { [weak self] in
                guard let self = self else { return }
                self.commandPanel?.beginInput(prompt: "OpenRouter model (e.g. openai/gpt-4o-mini)", value: self.state.openRouterModel ?? "", isSecret: false) { [weak self] model in
                    self?.state.setOpenRouterModel(model)
                    self?.syncLLMService()
                }
            },
            PaletteCommand(title: "Use OpenRouter", shortcut: state.llmProvider == .openRouter ? "current" : "") { [weak self] in
                self?.selectProvider(.openRouter)
            },
        ]
        commandPanel?.push(title: "OpenRouter", commands: cmds)
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
        // Mouse reporting (button events + SGR coords) for trackpad/wheel scroll.
        print("\u{1B}[?1000h\u{1B}[?1006h", terminator: "")
        fflush(stdout)
    }

    private func exitAlternateScreen() {
        print("\u{1B}[?1000l\u{1B}[?1006l", terminator: "")
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

        // Trackpad / mouse-wheel scroll (SGR mouse reporting). Consume all mouse
        // events so clicks/drags don't leak into the editor as garbage.
        if let delta = mouseScrollDelta(string) {
            if delta != 0 {
                state.scrollByLines(delta * 3)
                render()
            }
            return
        }

        if let panel = commandPanel, panel.isVisible {
            // Bracketed paste (e.g. an API key): feed the inner text to the
            // panel, stripping newlines so a pasted \r doesn't submit.
            if let pasteContent = extractBracketedPaste(string) {
                for char in pasteContent where !char.isNewline {
                    panel.handleKey(char)
                }
                render()
                return
            }
            if string == "\u{1B}[A" {
                panel.moveSelection(-1)
                render()
                return
            }
            if string == "\u{1B}[B" {
                panel.moveSelection(1)
                render()
                return
            }
            for char in string {
                if char == Key.ctrlP {
                    toggleCommandPanel()
                    return
                }
                if char == Key.escape && panel.isOAuthInProgress {
                    openAIOAuth.cancel()
                }
                panel.handleKey(char)
            }
            render()
            return
        }
        
        if state.isReviewing {
            handleReviewInput(string)
            return
        }

        if let modal = llmModal, modal.isVisible {
            if string == "\u{1B}[A" { modal.historyPrevious(); return }
            if string == "\u{1B}[B" { modal.historyNext(); return }
            if let pasteContent = extractBracketedPaste(string) {
                for char in pasteContent where !char.isNewline { modal.handleCharacter(char) }
                return
            }
            for char in string { handleLLMModalInput(char) }
            return
        }

        if let pasteContent = extractBracketedPaste(string) {
            handlePaste(pasteContent)
            render()
            return
        }

        var needsRender = false

        for char in string {
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
                state.deleteWordBackward()
                needsRender = true
            case Key.ctrlSlash:
                state.toggleHelp()
                needsRender = true
            case Key.ctrlP:
                toggleCommandPanel()
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
        
        if char == Key.backspace {
            modal.handleBackspace()
            return
        }
        
        modal.handleCharacter(char)
    }
    
    /// Push the current provider + all credentials into the LLM service.
    private func syncLLMService() {
        llmService.openRouterKey = state.openRouterKey
        llmService.openRouterModel = state.openRouterModel
        llmService.setProvider(state.llmProvider, openAIAccessToken: state.openAIAccessToken)
    }

    /// Start/stop a ~10fps re-render loop while the LLM spinner is on screen.
    private func updateSpinnerTimer() {
        let animating = llmModal?.isAnimating ?? false
        if animating, spinnerTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.render() }
            timer.resume()
            spinnerTimer = timer
        } else if !animating, let timer = spinnerTimer {
            timer.cancel()
            spinnerTimer = nil
        }
    }

    private func showLLMModal() {
        let doc = state.document
        let startLine: Int, endLine: Int
        if let selection = doc.selectionRange {
            startLine = selection.start.line
            endLine = selection.end.line
        } else if let para = doc.currentParagraphRange {
            startLine = para.start.line
            endLine = para.end.line
        } else {
            startLine = doc.cursorLine
            endLine = doc.cursorLine
        }
        reviewRange = (startLine, endLine)
        // Edits operate on whole lines (sections), so send the full lines as context.
        let context = doc.lines[startLine...endLine].joined(separator: "\n")
        llmModal?.show(withContext: context)
    }

    private func enterReview(with text: String) {
        guard let range = reviewRange else { return }
        reviewRange = nil
        state.beginReview(startLine: range.startLine, endLine: range.endLine, proposed: text)
        render()
    }

    private func handleReviewInput(_ string: String) {
        // Ignore escape sequences (arrows etc.) so a leading ESC isn't read as reject.
        if string.first == Key.escape && string.count > 1 { return }
        for char in string {
            switch char {
            case "y", "Y", Key.tab, Key.enter:
                state.acceptPendingEdit()
                render()
                return
            case "n", "N", Key.escape:
                state.rejectPendingEdit()
                render()
                return
            default:
                break
            }
        }
    }
    
    private func handleArrowKey(_ key: ArrowKey) {
        let size = getTerminalSize()
        let viewportHeight = size.height - 3
        
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
        case .ctrlUp, .home:
            state.goToTop()
        case .ctrlDown, .end:
            state.goToBottom()
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
        // Wrap the frame in synchronized-update mode (?2026) so the terminal
        // shows it atomically — no flicker/tearing while repainting big frames.
        print("\u{1B}[?2026h\u{1B}[H\(output)\u{1B}[0J\u{1B}[\(size.height);\(size.width)H\u{1B}[?2026l", terminator: "")
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
        // The gutter doubles as the configurable left margin.
        if state.showLineNumbers {
            let maxLineNum = state.document.lines.count
            return state.leftMargin + String(maxLineNum).count + 1
        }
        return state.leftMargin
    }

    private func renderGutter(lineNumber: Int, width: Int) -> String {
        if state.showLineNumbers {
            let numStr = String(lineNumber)
            let padding = String(repeating: " ", count: max(0, width - numStr.count - 1))
            return "\(Theme.gutter)\(padding)\(numStr) \(Theme.reset)"
        }
        return String(repeating: " ", count: max(0, width))
    }
    
    private func renderEditor(width: Int, height: Int) -> String {
        // Top bar (filename + optional markdown title) + status + hint bars.
        var reservedLines = 3

        let modalLines = llmModal?.render(width: width) ?? []
        if !modalLines.isEmpty {
            reservedLines += modalLines.count
        }

        let contentHeight = height - reservedLines
        let gutter = gutterWidth()
        let contentWidth = width - gutter

        state.setViewportWidth(contentWidth)
        state.adjustScroll(viewportHeight: contentHeight, viewportWidth: contentWidth)

        let margin = String(repeating: " ", count: state.leftMargin)
        var lines: [String] = [padToWidth(margin + renderTopBar(width: width - state.leftMargin), width: width)]

        var content: [String]
        switch state.viewMode {
        case .normal:
            content = renderNormalMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        case .raw:
            content = renderRawMode(width: contentWidth, height: contentHeight, gutterWidth: gutter)
        }

        while content.count < contentHeight {
            let emptyGutter = renderGutter(lineNumber: 0, width: gutter).replacingOccurrences(of: String(0), with: " ")
            content.append(padToWidth(emptyGutter, width: width))
        }
        lines += content

        for modalLine in modalLines {
            lines.append(padToWidth(modalLine, width: width))
        }
        
        lines.append(padToWidth(renderStatusBar(width: width), width: width))
        
        if state.isReviewing {
            lines.append(padToWidth(renderReviewHintBar(width: width), width: width))
        } else if state.showHelp {
            lines.append(padToWidth(renderHelpBar(width: width), width: width))
        } else {
            lines.append(padToWidth(renderHintBar(width: width), width: width))
        }

        overlayCommandPanel(into: &lines, width: width, height: height)

        // Erase to end of each line so wide glyphs / shorter frames leave no residue.
        return lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n")
    }

    private func overlayCommandPanel(into lines: inout [String], width: Int, height: Int) {
        guard let overlay = commandPanel?.render(width: width, height: height) else { return }
        let top = overlay.top
        let left = overlay.left
        let bw = overlay.width
        let rows = overlay.lines.count

        // Translucent drop shadow: 2 cols to the right (shifted down 1) + one
        // bottom row (shifted right 2). Underlying text is dimmed, not erased.
        for i in 1...rows {
            let row = top + i
            if row >= 0 && row < lines.count {
                lines[row] = applyShadow(to: lines[row], at: left + bw, count: 2)
            }
        }
        let bottomRow = top + rows
        if bottomRow >= 0 && bottomRow < lines.count {
            lines[bottomRow] = applyShadow(to: lines[bottomRow], at: left + 2, count: bw)
        }

        // The panel box itself.
        for (i, boxLine) in overlay.lines.enumerated() {
            let row = top + i
            if row >= 0 && row < lines.count {
                lines[row] = spliceVisible(base: lines[row], insert: boxLine, at: left, insertWidth: bw, width: width)
            }
        }
    }

    /// Re-tint `count` visible columns of `base` starting at column `at` with the
    /// translucent shadow style, keeping the underlying glyphs (Norton-style shadow).
    private func applyShadow(to base: String, at: Int, count: Int) -> String {
        let chars = Array(base)
        let n = chars.count
        var i = 0
        var col = 0
        var active = ""
        var out = ""

        func readEscape() -> String {
            var esc = ""
            while i < n {
                let c = chars[i]
                esc.append(c)
                i += 1
                if c.isLetter { break }
            }
            return esc
        }

        while i < n && col < at {
            let c = chars[i]
            if c == "\u{1B}" {
                let esc = readEscape()
                out += esc
                if esc == Theme.reset { active = "" } else { active += esc }
            } else {
                out.append(c)
                col += displayWidth(c)
                i += 1
            }
        }
        if col < at {
            out += String(repeating: " ", count: at - col)
        }

        out += Theme.reset + Theme.shadowStyle
        var shaded = 0
        while i < n && shaded < count {
            let c = chars[i]
            if c == "\u{1B}" {
                _ = readEscape()   // drop original styling inside the shadow
            } else {
                out.append(c)
                shaded += displayWidth(c)
                i += 1
            }
        }
        if shaded < count {
            out += String(repeating: " ", count: count - shaded)
        }

        out += Theme.reset + active
        if i < n {
            out += String(chars[i..<n])
        }
        return out
    }

    /// Splice `insert` (visible width `insertWidth`) into `base` at visible column `at`,
    /// preserving base content (and its ANSI styling) on both sides.
    private func spliceVisible(base: String, insert: String, at: Int, insertWidth: Int, width: Int) -> String {
        let chars = Array(base)
        let n = chars.count
        var i = 0
        var col = 0
        var active = ""
        var out = ""

        func readEscape() -> String {
            var esc = ""
            while i < n {
                let c = chars[i]
                esc.append(c)
                i += 1
                if c.isLetter { break }
            }
            return esc
        }

        while i < n && col < at {
            let c = chars[i]
            if c == "\u{1B}" {
                let esc = readEscape()
                out += esc
                if esc == Theme.reset { active = "" } else { active += esc }
            } else {
                out.append(c)
                col += displayWidth(c)
                i += 1
            }
        }
        if col < at {
            out += String(repeating: " ", count: at - col)
        }

        out += Theme.reset + insert + Theme.reset

        var skipped = 0
        while i < n && skipped < insertWidth {
            let c = chars[i]
            if c == "\u{1B}" {
                let esc = readEscape()
                if esc == Theme.reset { active = "" } else { active += esc }
            } else {
                skipped += displayWidth(c)
                i += 1
            }
        }

        out += active
        if i < n {
            out += String(chars[i..<n])
        }
        return out
    }

    private func toggleCommandPanel() {
        guard let panel = commandPanel else { return }
        if panel.isVisible {
            openAIOAuth.cancel()
            panel.hide()
        } else {
            panel.setCommands(buildCommands())
            panel.show()
        }
        render()
    }

    private func startOpenAIOAuth() {
        commandPanel?.setOAuthStatus(url: "", message: "Starting...")
        openAIOAuth.start(
            onUpdate: { [weak self] url, message in
                self?.commandPanel?.setOAuthStatus(url: url, message: message)
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let tokens):
                    self.state.setOpenAITokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt)
                    self.state.setLLMProvider(.openaiOAuth)
                    self.syncLLMService()
                    self.commandPanel?.hide()
                case .failure(let err):
                    self.commandPanel?.setError(err.localizedDescription)
                }
            }
        )
    }
    
    private func renderNormalMode(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        let selection = doc.selectionRange
        
        // During review use the non-wrapped path so the inline diff is simple
        // to splice in (long diff lines clip horizontally rather than wrap).
        if state.wordWrap && state.pendingEdit == nil {
            return renderNormalModeWrapped(width: width, height: height, gutterWidth: gutterWidth)
        }
        
        let startLine = state.scrollOffset
        let endLine = min(doc.lines.count, startLine + height)
        let tableMap = selection == nil ? tableRenderMap(width: width) : [:]

        var inCodeBlock = isInsideCodeBlock(beforeLine: startLine, doc: doc)
        let inFrontmatterAtStart = isInsideFrontmatter(lineIndex: startLine, doc: doc)
        var inFrontmatter = inFrontmatterAtStart
        
        for i in startLine..<endLine {
            // Inline LLM-edit review: emit the diff block in place of the sector.
            if let pe = state.pendingEdit, i >= pe.startLine, i <= pe.endLine {
                if i == pe.startLine {
                    for dl in pe.diff {
                        if output.count >= height { break }
                        output.append(renderDiffLine(dl, gutterWidth: gutterWidth, width: width))
                    }
                }
                continue
            }

            let line = doc.lines[i]
            let isCodeDelimiter = MarkdownLineParser.isCodeBlockDelimiter(line)
            let isFmDelimiter = isFrontmatterDelimiter(line)
            
            if isCodeDelimiter && !inFrontmatter {
                inCodeBlock = !inCodeBlock
            }
            
            if isFmDelimiter && (i == 0 || inFrontmatter) {
                if i == 0 {
                    inFrontmatter = true
                } else {
                    inFrontmatter = false
                }
            }
            
            let isCursorLine = i == doc.cursorLine
            var renderedLine: String

            if let tableLine = tableMap[i] {
                renderedLine = tableLine
            } else if selection != nil {
                renderedLine = renderLineWithSelection(line: line, lineIndex: i, selection: selection, doc: doc)
            } else if isFmDelimiter && (i == 0 || isInsideFrontmatter(lineIndex: i, doc: doc) || (i > 0 && isInsideFrontmatter(lineIndex: i - 1, doc: doc))) {
                if isCursorLine {
                    renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                } else {
                    renderedLine = renderFrontmatterDelimiter(width: width)
                }
            } else if inFrontmatter || isInsideFrontmatter(lineIndex: i, doc: doc) {
                if isCursorLine {
                    renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                } else if let prop = parseFrontmatterProp(line) {
                    renderedLine = renderFrontmatterProp(key: prop.key, value: prop.value)
                } else {
                    renderedLine = "\(Theme.textMuted)\(line)\(Theme.reset)"
                }
            } else if inCodeBlock || isCodeDelimiter {
                renderedLine = renderCodeBlockLine(line: line, isCursorLine: isCursorLine, cursorColumn: doc.cursorColumn)
            } else {
                if let quote = parseQuoteLine(line) {
                    if isCursorLine {
                        renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                    } else {
                        renderedLine = renderQuoteLine(quote)
                    }
                } else if let list = parseListLine(line) {
                    if isCursorLine {
                        renderedLine = renderLineRaw(line: line, cursorColumn: doc.cursorColumn)
                    } else {
                        renderedLine = renderListLine(list)
                    }
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
            }
            
            let gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
            let scrolled = applyHorizontalScroll(renderedLine, scrollX: state.scrollX, width: width)
            output.append(padToWidth(gutter + scrolled, width: gutterWidth + width))
        }

        return output
    }

    private func renderDiffLine(_ dl: DiffLine, gutterWidth: Int, width: Int) -> String {
        let color: String, text: String
        switch dl {
        case .same(let s): color = Theme.textMuted; text = "  \(s)"
        case .del(let s):  color = Theme.diffDel;   text = "- \(s)"
        case .add(let s):  color = Theme.diffAdd;   text = "+ \(s)"
        }
        let styled = "\(color)\(text)\(Theme.reset)"
        let scrolled = applyHorizontalScroll(styled, scrollX: 0, width: width)
        let gutter = String(repeating: " ", count: gutterWidth)
        return padToWidth(gutter + scrolled, width: gutterWidth + width)
    }

    // MARK: - Markdown tables

    private enum TableRole { case header, separator, data, top, bottom }

    private func isBlankLine(_ line: String) -> Bool {
        return line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func isTableSeparatorLine(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") && t.contains("|") else { return false }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.components(separatedBy: "|")
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            if c.isEmpty || !c.contains("-") { return false }
            if !c.allSatisfy({ $0 == "-" || $0 == ":" }) { return false }
        }
        return true
    }

    private func isTableRowLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("|") && !t.isEmpty
    }

    private func parseTableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func truncateCell(_ s: String, to maxWidth: Int) -> String {
        guard s.displayWidth > maxWidth else { return s }
        var out = ""
        var w = 0
        for ch in s {
            let cw = displayWidth(ch)
            if w + cw > maxWidth { break }
            out.append(ch)
            w += cw
        }
        return out
    }

    /// Map of line index -> styled table-row string. Blocks containing the cursor
    /// are omitted so they render raw (and stay editable).
    private func tableRenderMap(width: Int) -> [Int: String] {
        let lines = state.document.lines
        let n = lines.count
        let cursorLine = state.document.cursorLine
        var map: [Int: String] = [:]
        var i = 0
        while i < n {
            if isTableRowLine(lines[i]) && !isTableSeparatorLine(lines[i]) &&
               i + 1 < n && isTableSeparatorLine(lines[i + 1]) {
                var e = i + 2
                while e < n && isTableRowLine(lines[e]) && !isTableSeparatorLine(lines[e]) {
                    e += 1
                }
                let block = i..<e

                var numCols = 0
                var rowCells: [[String]] = []
                for r in block where r != i + 1 {
                    let cells = parseTableCells(lines[r])
                    numCols = max(numCols, cells.count)
                    rowCells.append(cells)
                }
                var widths = [Int](repeating: 1, count: numCols)
                for cells in rowCells {
                    for c in 0..<numCols where c < cells.count {
                        widths[c] = max(widths[c], cells[c].displayWidth)
                    }
                }

                if !block.contains(cursorLine) {
                    for r in block {
                        let role: TableRole = r == i ? .header : (r == i + 1 ? .separator : .data)
                        map[r] = renderTableRow(line: lines[r], role: role, widths: widths, numCols: numCols, width: width)
                    }
                    // Full-box borders reuse the blank lines surrounding the table.
                    if state.fullTable {
                        if i - 1 >= 0 && isBlankLine(lines[i - 1]) && cursorLine != i - 1 {
                            map[i - 1] = renderTableRow(line: "", role: .top, widths: widths, numCols: numCols, width: width)
                        }
                        if e < n && isBlankLine(lines[e]) && cursorLine != e {
                            map[e] = renderTableRow(line: "", role: .bottom, widths: widths, numCols: numCols, width: width)
                        }
                    }
                }
                i = e
            } else {
                i += 1
            }
        }
        return map
    }

    private func renderTableRow(line: String, role: TableRole, widths: [Int], numCols: Int, width: Int) -> String {
        let border = Theme.textMuted
        var out = ""

        if role == .separator || role == .top || role == .bottom {
            let (lead, junction, tail): (String, String, String)
            switch role {
            case .top: (lead, junction, tail) = ("┌", "┬", "┐")
            case .bottom: (lead, junction, tail) = ("└", "┴", "┘")
            default: (lead, junction, tail) = ("├", "┼", "┤")
            }
            out += "\(border)\(lead)"
            for c in 0..<numCols {
                out += String(repeating: "─", count: widths[c] + 2)
                out += (c == numCols - 1) ? tail : junction
            }
            out += Theme.reset
            return truncateToWidth(out, width: width)
        }

        let cells = parseTableCells(line)
        let style = role == .header ? "\(Theme.bold)\(Theme.textPrimary)" : Theme.textPrimary
        out += "\(border)│\(Theme.reset)"
        for c in 0..<numCols {
            let raw = c < cells.count ? cells[c] : ""
            let cell = truncateCell(raw, to: widths[c])
            let pad = String(repeating: " ", count: max(0, widths[c] - cell.displayWidth))
            out += " \(style)\(cell)\(Theme.reset)\(pad) \(border)│\(Theme.reset)"
        }
        return truncateToWidth(out, width: width)
    }


    private func renderNormalModeWrapped(width: Int, height: Int, gutterWidth: Int) -> [String] {
        var output: [String] = []
        let doc = state.document
        let selection = doc.selectionRange
        let tableMap = selection == nil ? tableRenderMap(width: width) : [:]

        var visualLine = 0
        var inCodeBlock = false
        
        for i in 0..<doc.lines.count {
            let line = doc.lines[i]
            let isCodeDelimiter = MarkdownLineParser.isCodeBlockDelimiter(line)
            let isFmDelimiter = isFrontmatterDelimiter(line)
            let inFrontmatter = isInsideFrontmatter(lineIndex: i, doc: doc)
            
            if isCodeDelimiter && !inFrontmatter && !isFmDelimiter {
                inCodeBlock = !inCodeBlock
            }

            if let tableLine = tableMap[i] {
                if visualLine >= state.scrollOffset && output.count < height {
                    let gutter = renderGutter(lineNumber: i + 1, width: gutterWidth)
                    output.append(padToWidth(gutter + tableLine, width: gutterWidth + width))
                }
                visualLine += 1
                continue
            }

            let isCursorLine = i == doc.cursorLine
            let spans = MarkdownLineParser.parse(line)
            let headingSpan = spans.first.flatMap { isHeadingSpan($0) ? $0 : nil }
            let cursorInSpan = isCursorLine ? MarkdownLineParser.spanContainingCursor(column: doc.cursorColumn, spans: spans) : nil
            
            let (lineToWrap, mode) = resolveLineMode(
                line: line,
                lineIndex: i,
                doc: doc,
                isCursorLine: isCursorLine,
                headingSpan: headingSpan,
                cursorInSpan: cursorInSpan,
                inCodeBlock: inCodeBlock,
                isCodeDelimiter: isCodeDelimiter,
                hasSelection: selection != nil,
                spans: spans,
                width: width
            )
            
            let wrappedSegments = wrapLine(lineToWrap, width: width)
            
            for (segmentIndex, wrapped) in wrappedSegments.enumerated() {
                guard visualLine >= state.scrollOffset && output.count < height else {
                    visualLine += 1
                    continue
                }
                
                let segment = wrapped.segment
                let segmentStart = wrapped.startOffset
                let localCursor = computeLocalCursor(
                    isCursorLine: isCursorLine,
                    cursorColumn: doc.cursorColumn,
                    segmentStart: segmentStart,
                    segmentLength: segment.count,
                    isLastSegment: segmentIndex == wrappedSegments.count - 1,
                    width: width
                )
                
                let renderedLine = renderSegment(
                    segment: segment,
                    mode: mode,
                    localCursor: localCursor,
                    lineIndex: i,
                    segmentStart: segmentStart,
                    selection: selection,
                    doc: doc,
                    spans: spans
                )
                
                let gutter = segmentIndex == 0
                    ? renderGutter(lineNumber: i + 1, width: gutterWidth)
                    : String(repeating: " ", count: gutterWidth)
                
                output.append(padToWidth(gutter + renderedLine, width: gutterWidth + width))
                visualLine += 1
            }
            
            if isCursorLine && doc.cursorColumn == lineToWrap.count {
                if let lastSeg = wrappedSegments.last, lastSeg.segment.count == width {
                    if visualLine >= state.scrollOffset && output.count < height {
                        let gutter = String(repeating: " ", count: gutterWidth)
                        output.append(padToWidth(gutter + "\(Theme.inverse) \(Theme.reset)", width: gutterWidth + width))
                    }
                    visualLine += 1
                }
            }
        }
        
        return output
    }
    
    private func resolveLineMode(
        line: String,
        lineIndex: Int,
        doc: Document,
        isCursorLine: Bool,
        headingSpan: MarkdownSpan?,
        cursorInSpan: MarkdownSpan?,
        inCodeBlock: Bool,
        isCodeDelimiter: Bool,
        hasSelection: Bool,
        spans: [MarkdownSpan],
        width: Int
    ) -> (line: String, mode: SegmentRenderMode) {
        if hasSelection {
            return (line, .selection)
        }
        
        let isFmDelimiter = isFrontmatterDelimiter(line)
        let inFrontmatter = isInsideFrontmatter(lineIndex: lineIndex, doc: doc)
        let isFmClosing = isFmDelimiter && lineIndex > 0 && isInsideFrontmatter(lineIndex: lineIndex - 1, doc: doc)
        
        if isFmDelimiter && (lineIndex == 0 || isFmClosing) {
            if isCursorLine {
                return (line, .raw)
            }
            return (String(repeating: "─", count: width), .frontmatterDelimiter)
        }
        
        if inFrontmatter {
            if isCursorLine {
                return (line, .raw)
            }
            if let prop = parseFrontmatterProp(line) {
                return (line, .frontmatterProp(key: prop.key, value: prop.value))
            }
            return (line, .codeBlock)
        }
        
        if inCodeBlock || isCodeDelimiter {
            return (line, .codeBlock)
        }
        if let heading = headingSpan {
            if isCursorLine {
                return (line, .raw)
            }
            return (heading.content, .heading(headingStyle(heading.kind)))
        }
        if let quote = parseQuoteLine(line) {
            if isCursorLine {
                return (line, .raw)
            }
            let render = makeQuoteRender(quote)
            return (render.prefix + quote.content, .quote(render))
        }
        if let list = parseListLine(line) {
            if isCursorLine {
                return (line, .raw)
            }
            let render = makeListRender(list)
            return (render.prefix + list.content, .list(render))
        }
        if isCursorLine && cursorInSpan != nil {
            return (line, .raw)
        }
        return (line, .collapsed(spans))
    }
    
    private func computeLocalCursor(
        isCursorLine: Bool,
        cursorColumn: Int,
        segmentStart: Int,
        segmentLength: Int,
        isLastSegment: Bool,
        width: Int
    ) -> Int {
        guard isCursorLine else { return -1 }
        let segmentEnd = segmentStart + segmentLength
        let cursorInSegment = cursorColumn >= segmentStart && cursorColumn < segmentEnd
        let cursorAtSegmentEnd = isLastSegment && cursorColumn == segmentEnd && segmentLength < width
        return (cursorInSegment || cursorAtSegmentEnd) ? cursorColumn - segmentStart : -1
    }
    
    private func renderSegment(
        segment: String,
        mode: SegmentRenderMode,
        localCursor: Int,
        lineIndex: Int,
        segmentStart: Int,
        selection: (start: CursorPosition, end: CursorPosition)?,
        doc: Document,
        spans: [MarkdownSpan]
    ) -> String {
        switch mode {
        case .selection:
            return renderSegmentWithSelection(segment: segment, lineIndex: lineIndex, segmentStart: segmentStart, selection: selection, doc: doc)
        case .codeBlock:
            return renderCodeBlockSegment(segment: segment, cursorColumn: localCursor)
        case .raw:
            return renderLineRaw(line: segment, cursorColumn: localCursor)
        case .heading(let style):
            return renderStyledSegment(segment: segment, style: style, cursorColumn: localCursor)
        case .collapsed(let spans):
            return renderSegmentCollapsed(segment: segment, segmentStart: segmentStart, spans: spans, cursorColumn: localCursor)
        case .list(let render):
            return renderListSegment(segment: segment, segmentStart: segmentStart, render: render)
        case .quote(let render):
            return renderQuoteSegment(segment: segment, segmentStart: segmentStart, render: render)
        case .frontmatterDelimiter:
            return renderFrontmatterDelimiter(width: segment.count > 0 ? segment.count : 40)
        case .frontmatterProp(let key, let value):
            return renderFrontmatterProp(key: key, value: value)
        }
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

    private func parseListLine(_ line: String) -> ListLine? {
        let chars = Array(line)
        var i = 0
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }
        guard i + 4 < chars.count else { return nil }
        let bullet = chars[i]
        guard bullet == "-" || bullet == "*" || bullet == "+" else { return nil }
        guard chars[i + 1] == " " else { return nil }
        let indent = i > 0 ? String(chars[0..<i]) : ""

        if chars[i + 2] == "[", chars[i + 4] == "]" {
            let stateChar = chars[i + 3]
            let state: TodoState
            switch stateChar {
            case " ": state = .unchecked
            case "x", "X": state = .checked
            case "*": state = .partial
            default: return nil
            }
            var j = i + 5
            if j < chars.count && chars[j] == " " {
                j += 1
            }
            let content = j < chars.count ? String(chars[j...]) : ""
            return ListLine(indent: indent, kind: .todo(state), content: content)
        }

        let j = i + 2
        let content = j < chars.count ? String(chars[j...]) : ""
        return ListLine(indent: indent, kind: .bullet, content: content)
    }

    private func makeListRender(_ list: ListLine) -> ListRender {
        let prefix = listPrefix(for: list)
        let prefixStyle = listPrefixStyle(for: list.kind)
        let contentSpans = MarkdownLineParser.parse(list.content)
        return ListRender(prefix: prefix, prefixStyle: prefixStyle, contentSpans: contentSpans)
    }

    private func listPrefix(for list: ListLine) -> String {
        let marker: String
        switch list.kind {
        case .bullet:
            marker = "▪"
        case .todo(let state):
            switch state {
            case .unchecked: marker = "□"
            case .checked: marker = "■"
            case .partial: marker = "▣"
            }
        }
        return list.indent + marker + " "
    }

    private func listPrefixStyle(for kind: ListLineKind) -> String {
        switch kind {
        case .bullet:
            return Theme.accent
        case .todo:
            return Theme.accent
        }
    }

    private func renderListLine(_ list: ListLine) -> String {
        let render = makeListRender(list)
        let styledPrefix = "\(render.prefixStyle)\(render.prefix)\(Theme.reset)"
        let renderedContent = renderLineCollapsed(line: list.content, spans: render.contentSpans, isCursorLine: false, cursorColumn: 0)
        return styledPrefix + renderedContent
    }

    private func renderListSegment(segment: String, segmentStart: Int, render: ListRender) -> String {
        let prefixLen = render.prefix.count
        let segmentChars = Array(segment)
        let segmentEnd = segmentStart + segmentChars.count
        var result = ""

        if segmentStart < prefixLen {
            let prefixCount = min(prefixLen - segmentStart, segmentChars.count)
            if prefixCount > 0 {
                let prefixPart = String(segmentChars[0..<prefixCount])
                result += "\(render.prefixStyle)\(prefixPart)\(Theme.reset)"
            }
        }

        if segmentEnd > prefixLen {
            let contentStartIndex = max(0, prefixLen - segmentStart)
            let contentSegment = String(segmentChars[contentStartIndex...])
            let contentSegmentStart = max(0, segmentStart - prefixLen)
            result += renderSegmentCollapsed(segment: contentSegment, segmentStart: contentSegmentStart, spans: render.contentSpans, cursorColumn: -1)
        }

        return result
    }

    private func parseQuoteLine(_ line: String) -> QuoteLine? {
        let chars = Array(line)
        var i = 0
        while i < chars.count && chars[i].isWhitespace {
            i += 1
        }
        guard i < chars.count, chars[i] == ">" else { return nil }
        var j = i + 1
        if j < chars.count && chars[j] == " " {
            j += 1
        }
        let indent = i > 0 ? String(chars[0..<i]) : ""
        let content = j < chars.count ? String(chars[j...]) : ""
        return QuoteLine(indent: indent, content: content)
    }

    private func makeQuoteRender(_ quote: QuoteLine) -> QuoteRender {
        let prefix = quote.indent + "| "
        let prefixStyle = Theme.textMuted
        let contentSpans = MarkdownLineParser.parse(quote.content)
        return QuoteRender(prefix: prefix, prefixStyle: prefixStyle, contentSpans: contentSpans)
    }

    private func renderQuoteLine(_ quote: QuoteLine) -> String {
        let render = makeQuoteRender(quote)
        let styledPrefix = "\(render.prefixStyle)\(render.prefix)\(Theme.reset)"
        let renderedContent = renderLineCollapsed(line: quote.content, spans: render.contentSpans, isCursorLine: false, cursorColumn: 0)
        return styledPrefix + renderedContent
    }

    private func renderQuoteSegment(segment: String, segmentStart: Int, render: QuoteRender) -> String {
        let prefixLen = render.prefix.count
        let segmentChars = Array(segment)
        let segmentEnd = segmentStart + segmentChars.count
        var result = ""

        if segmentStart < prefixLen {
            let prefixCount = min(prefixLen - segmentStart, segmentChars.count)
            if prefixCount > 0 {
                let prefixPart = String(segmentChars[0..<prefixCount])
                result += "\(render.prefixStyle)\(prefixPart)\(Theme.reset)"
            }
        }

        if segmentEnd > prefixLen {
            let contentStartIndex = max(0, prefixLen - segmentStart)
            let contentSegment = String(segmentChars[contentStartIndex...])
            let contentSegmentStart = max(0, segmentStart - prefixLen)
            result += renderSegmentCollapsed(segment: contentSegment, segmentStart: contentSegmentStart, spans: render.contentSpans, cursorColumn: -1)
        }

        return result
    }

    private func renderFrontmatterDelimiter(width: Int) -> String {
        let line = String(repeating: "─", count: max(3, width))
        return "\(Theme.textMuted)\(line)\(Theme.reset)"
    }

    private func renderFrontmatterProp(key: String, value: String) -> String {
        return "\(Theme.textSecondary)\(key):\(Theme.reset) \(Theme.textPrimary)\(value)\(Theme.reset)"
    }

    private func isFrontmatterDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---"
    }

    private func parseFrontmatterProp(_ line: String) -> (key: String, value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let valueStart = line.index(after: colonIndex)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private func isInsideFrontmatter(lineIndex: Int, doc: Document) -> Bool {
        guard lineIndex > 0 else { return false }
        guard doc.lines.count > 0 else { return false }
        let firstLine = doc.lines[0].trimmingCharacters(in: .whitespaces)
        guard firstLine == "---" else { return false }
        
        var foundClosing = false
        for i in 1..<doc.lines.count {
            let line = doc.lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" {
                if i >= lineIndex {
                    return !foundClosing
                }
                foundClosing = true
                break
            }
        }
        return !foundClosing && lineIndex > 0
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
        guard cursorColumn >= 0 else { return line }
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
                visibleCount += displayWidth(char)
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
                let w = displayWidth(char)
                if visibleCount + w <= width {
                    result.append(char)
                    visibleCount += w
                } else {
                    // End any active styling and stop
                    result.append(Theme.reset)
                    break
                }
            }
        }
        
        return result
    }
    
    private func renderTopBar(width: Int) -> String {
        let name = (state.filePath as NSString).lastPathComponent
        // Markdown glyph (Nerd Font) before the filename.
        var content = "\(Theme.accent)\u{f48a}\(Theme.reset)  \(Theme.textSecondary)\(name)\(Theme.reset)"
        if let title = documentTitle() {
            content += "\(Theme.textMuted) — \(title)\(Theme.reset)"
        }
        return truncateToWidth(content, width: width)
    }

    /// The document's title: frontmatter `title:`, else the first H1 heading.
    private func documentTitle() -> String? {
        let lines = state.document.lines

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "---" { break }
                if t.lowercased().hasPrefix("title:") {
                    let value = t.dropFirst("title:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !value.isEmpty { return String(value) }
                }
            }
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") {
                let value = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
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
            leftParts.append("\(Theme.accent)◉\(Theme.statusBarText)")
        }
        let left = leftParts.joined(separator: " ")
        
        let leftVisibleLen = state.isDirty && !state.showSavedIndicator ? leftParts.reduce(0) { $0 + ($1.contains("◉") ? 1 : $1.count) } + leftParts.count - 1 : left.count
        let right = "\(doc.wordCount) words | Ln \(doc.cursorLine + 1), Col \(doc.cursorColumn + 1)"
        let contentWidth = width - 1
        let padding = contentWidth - leftVisibleLen - right.count
        let spaces = String(repeating: " ", count: max(0, padding))
        return "\(Theme.accent)▌\(Theme.statusBarBg)\(Theme.statusBarText)\(left)\(spaces)\(right)\(Theme.reset)"
    }
    
    private func renderHelpBar(width: Int) -> String {
        let shortcuts: [(key: String, desc: String)] = [
            ("^/", "help"),
            ("^P", "commands"),
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

    private func renderHintBar(width: Int) -> String {
        return "\(Theme.accent)ctrl+p \(Theme.textMuted)commands   \(Theme.accent)ctrl+/ \(Theme.textMuted)help\(Theme.reset)"
    }

    private func renderReviewHintBar(width: Int) -> String {
        return "\(Theme.diffAdd)y/⇥ \(Theme.textMuted)accept   \(Theme.diffDel)n/esc \(Theme.textMuted)reject   \(Theme.textMuted)AI edit review\(Theme.reset)"
    }

    /// Parse SGR mouse reports (CSI < b ; x ; y M/m). Returns the net wheel
    /// delta (+down / −up) if the input is mouse data, or nil if it isn't.
    /// Non-wheel mouse events (clicks/drags) yield 0 (consumed, ignored).
    private func mouseScrollDelta(_ string: String) -> Int? {
        guard string.contains("\u{1B}[<") else { return nil }
        var delta = 0
        for part in string.components(separatedBy: "\u{1B}[<").dropFirst() {
            let button = Int(part.prefix { $0.isNumber }) ?? -1
            if button == 64 { delta -= 1 }       // wheel up
            else if button == 65 { delta += 1 }  // wheel down
        }
        return delta
    }

    private func extractBracketedPaste(_ input: String) -> String? {
        let pasteStart = "\u{1B}[200~"
        let pasteEnd = "\u{1B}[201~"
        
        guard let startRange = input.range(of: pasteStart),
              let endRange = input.range(of: pasteEnd) else {
            return nil
        }
        
        return String(input[startRange.upperBound..<endRange.lowerBound])
    }
    
    private func handlePaste(_ content: String) {
        if let modal = llmModal, modal.isVisible {
            for char in content {
                modal.handleCharacter(char)
            }
        } else {
            state.pasteText(content)
        }
    }
    
    private func quit() {
        state.persistCursorPosition()
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
    case ctrlUp, ctrlDown
    case ctrlShiftLeft, ctrlShiftRight
    case pageUp, pageDown
    case home, end
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
        case ss3
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
            if character == "O" {
                state = .ss3
                return true
            }
            state = .initial
            return false

        case .ss3:
            state = .initial
            switch character {
            case "H": arrowKey = .home
            case "F": arrowKey = .end
            default: break
            }
            return true
            
        case .bracket:
            if character == "1" {
                state = .modifier
                return true
            }
            if character == "5" || character == "6" || character == "4" {
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
            case "H": arrowKey = .home
            case "F": arrowKey = .end
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
                } else if buffer[0] == "4" {
                    arrowKey = .end
                }
            }
            return true

        case .modifier:
            if character == ";" {
                state = .semicolon
                return true
            }
            // ESC [ 1 ~  == Home
            if character == "~" {
                arrowKey = .home
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
            case ("5", "A"): arrowKey = .ctrlUp
            case ("5", "B"): arrowKey = .ctrlDown
            // Ctrl+Shift+Arrow (modifier 6)
            case ("6", "C"): arrowKey = .ctrlShiftRight
            case ("6", "D"): arrowKey = .ctrlShiftLeft
            default: break
            }
            return true
        }
    }
}
