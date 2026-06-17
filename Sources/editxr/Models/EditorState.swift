import Foundation

enum ViewMode {
    case normal
    case raw
}

/// Focus mode: dim everything but the area around the cursor, fading toward
/// the background with distance. `line` fades whole lines by vertical
/// distance; `word` adds a horizontal fade so only the word under the cursor
/// stays fully lit. Not persisted — it always starts off.
enum FocusMode {
    case off
    case line
    case word

    /// Short label for the command palette / status bar.
    var label: String {
        switch self {
        case .off:  return "off"
        case .line: return "line"
        case .word: return "word"
        }
    }
}

struct DocumentSnapshot {
    let lines: [String]
    let cursorLine: Int
    let cursorColumn: Int
}

/// A single find match: a line and a Character-offset range within it.
struct SearchMatch {
    let line: Int
    let column: Int
    let length: Int
}

class EditorState {
    let filePath: String
    var document: Document
    var viewMode: ViewMode = .normal
    var focusMode: FocusMode = .off
    var showStatusBar: Bool = true
    var showLineNumbers: Bool = false
    var statusBarBig: Bool = true
    var wordWrap: Bool = true
    var scrollPastEnd: Bool = true
    var fullTable: Bool = true
    /// Contextual status-bar hints (e.g. "^T toggle task" on a task line).
    var contextHelp: Bool = true
    /// Block mode: at column 0 of a structured line, show it rendered (a "handle")
    /// and only drop to raw once you move right or start typing.
    var blockMode: Bool = true
    var leftMargin: Int = 1
    var themeName: ThemeName = .system
    var appearance: Appearance = .auto
    var isDirty: Bool = false
    var showSavedIndicator: Bool = false
    var scrollOffset: Int = 0
    var scrollX: Int = 0
    var pendingEdit: PendingEdit? = nil

    // Incremental find (Ctrl+F / Ctrl+G). `searchActive` drives the input bar;
    // the query + match list persist after committing so Ctrl+G keeps stepping.
    var searchActive: Bool = false
    var searchQuery: String = ""
    var searchMatches: [SearchMatch] = []
    var searchIndex: Int = 0
    private var searchOrigin: CursorPosition = CursorPosition(line: 0, column: 0)

    /// Syntax highlighter for non-Markdown files (nil → render as Markdown).
    let syntaxHighlighter: SyntaxHighlighter?

    var llmProvider: LLMProvider = .lmStudio
    private(set) var openRouterKey: String? = nil
    private(set) var openRouterModel: String? = nil
    private(set) var openAIAccessToken: String? = nil
    private(set) var openAIRefreshToken: String? = nil
    private(set) var openAIExpiresAt: Double? = nil
    
    private var clipboard: String = ""
    private var savedTimer: DispatchWorkItem?
    
    private var undoStack: [DocumentSnapshot] = []
    private var redoStack: [DocumentSnapshot] = []
    private let maxUndoLevels = 100
    var scrollMargin = 4   // scroll-off: keep the cursor this many rows from the edge
    private let scrollMarginX = 8
    
    var onSavedIndicatorChanged: (() -> Void)?
    
    init(filePath: String) {
        self.filePath = filePath
        self.document = Document()
        self.syntaxHighlighter = SyntaxRegistry.forFile(filePath)

        let config = Config.load()
        self.wordWrap = config.wordWrap
        self.scrollPastEnd = config.scrollPastEnd ?? true
        self.fullTable = config.fullTable ?? true
        self.contextHelp = config.contextHelp ?? true
        self.blockMode = config.blockMode ?? true
        self.leftMargin = max(0, min(8, config.leftMargin ?? 1))
        self.scrollMargin = max(0, min(20, config.scrollOff ?? 4))
        // Clay is the default on first run; a saved choice still wins.
        self.themeName = config.theme.flatMap(ThemeName.init(rawValue:)) ?? .clay
        self.appearance = config.appearance.flatMap(Appearance.init(rawValue:)) ?? .auto
        Theme.name = self.themeName
        Theme.mode = self.appearance.mode
        self.viewMode = config.renderMarkdown ? .normal : .raw
        self.showLineNumbers = config.showLineNumbers ?? false
        self.statusBarBig = config.statusBarBig ?? true
        self.llmProvider = config.llmProvider
        self.openRouterKey = config.openRouterKey
        self.openRouterModel = config.openRouterModel
        self.openAIAccessToken = config.openAIAccessToken
        self.openAIRefreshToken = config.openAIRefreshToken
        self.openAIExpiresAt = config.openAIExpiresAt
        
        loadFile()
        restoreCursorPosition()
    }

    /// Restore the cursor (and scroll) saved from a previous session, clamped
    /// to the current document so a shrunken file can't land out of bounds.
    private func restoreCursorPosition() {
        guard let pos = CursorStore.load(for: filePath), !document.lines.isEmpty else { return }
        let line = max(0, min(pos.line, document.lines.count - 1))
        let col = max(0, min(pos.column, document.lines[line].count))
        document.cursorLine = line
        document.cursorColumn = col
        scrollOffset = max(0, pos.scroll)
    }

    /// Persist the current cursor position; call when leaving the editor.
    func persistCursorPosition() {
        let pos = CursorStore.Position(
            line: document.cursorLine,
            column: document.cursorColumn,
            scroll: scrollOffset)
        CursorStore.save(pos, for: filePath)
    }
    
    func loadFile() {
        if FileManager.default.fileExists(atPath: filePath) {
            do {
                let content = try String(contentsOfFile: filePath, encoding: .utf8)
                document = Document(content: content)
            } catch {
                document = Document()
            }
        } else {
            document = Document()
        }
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
    }
    
    private func saveSnapshot() {
        let snapshot = DocumentSnapshot(
            lines: document.lines,
            cursorLine: document.cursorLine,
            cursorColumn: document.cursorColumn
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
    
    private func restoreSnapshot(_ snapshot: DocumentSnapshot) {
        document.lines = snapshot.lines
        document.cursorLine = snapshot.cursorLine
        document.cursorColumn = snapshot.cursorColumn
        document.clearSelection()
    }
    
    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        
        let currentSnapshot = DocumentSnapshot(
            lines: document.lines,
            cursorLine: document.cursorLine,
            cursorColumn: document.cursorColumn
        )
        redoStack.append(currentSnapshot)
        
        restoreSnapshot(snapshot)
        isDirty = true
    }
    
    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        
        let currentSnapshot = DocumentSnapshot(
            lines: document.lines,
            cursorLine: document.cursorLine,
            cursorColumn: document.cursorColumn
        )
        undoStack.append(currentSnapshot)
        
        restoreSnapshot(snapshot)
        isDirty = true
    }
    
    func save() {
        do {
            try document.content.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
            showSavedIndicator = true
            onSavedIndicatorChanged?()
            
            savedTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                self?.showSavedIndicator = false
                self?.onSavedIndicatorChanged?()
            }
            savedTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timer)
        } catch { }
    }
    
    func toggleViewMode() {
        viewMode = viewMode == .normal ? .raw : .normal
        saveConfig()
    }

    /// Cycle off → line → word → off. Deliberately not persisted to config.
    func cycleFocusMode() {
        switch focusMode {
        case .off:  focusMode = .line
        case .line: focusMode = .word
        case .word: focusMode = .off
        }
    }
    
    func toggleStatusBar() {
        showStatusBar.toggle()
    }
    
    func toggleLineNumbers() {
        showLineNumbers.toggle()
        saveConfig()
    }

    func toggleStatusBarBig() {
        statusBarBig.toggle()
        saveConfig()
    }
    
    func toggleWordWrap() {
        wordWrap.toggle()
        scrollX = 0
        saveConfig()
    }

    func toggleScrollPastEnd() {
        scrollPastEnd.toggle()
        saveConfig()
    }

    func toggleFullTable() {
        fullTable.toggle()
        saveConfig()
    }

    func toggleContextHelp() {
        contextHelp.toggle()
        saveConfig()
    }

    func toggleBlockMode() {
        blockMode.toggle()
        saveConfig()
    }

    func setLeftMargin(_ value: Int) {
        leftMargin = max(0, min(8, value))
        saveConfig()
    }

    func setScrollOff(_ value: Int) {
        scrollMargin = max(0, min(20, value))
        saveConfig()
    }

    /// Trackpad/wheel scroll: move the viewport directly and leave the cursor
    /// where it is. The cursor is only dragged once it would come within
    /// `scrollMargin` (the scroll-off) of the top/bottom edge.
    func scrollViewport(lines delta: Int, viewportHeight: Int, viewportWidth: Int) {
        guard !document.lines.isEmpty, delta != 0 else { return }
        lastViewportWidth = viewportWidth
        let wrapped = wordWrap && pendingEdit == nil && syntaxHighlighter == nil

        let total = wrapped ? countVisualLines(viewportWidth: viewportWidth) : document.lines.count
        let endSlack = scrollPastEnd ? viewportHeight / 2 : 0
        let maxScroll = max(0, total - viewportHeight + endSlack)
        let newOffset = max(0, min(maxScroll, scrollOffset + delta))
        let applied = newOffset - scrollOffset
        scrollOffset = newOffset
        guard applied != 0 else { return }

        func cursorVisual() -> Int { wrapped ? visualLineForCursor(viewportWidth: viewportWidth) : document.cursorLine }

        if applied > 0 {
            // Scrolled down: drag the cursor down if it rose above the top margin.
            let topLimit = scrollOffset + scrollMargin
            var steps = 0
            while cursorVisual() < topLimit && steps <= applied {
                let line = document.cursorLine, col = document.cursorColumn
                if wrapped { moveDownWrapped() } else { document.moveDown() }
                if document.cursorLine == line && document.cursorColumn == col { break }
                steps += 1
            }
        } else {
            // Scrolled up: drag the cursor up if it fell below the bottom margin.
            let bottomLimit = scrollOffset + viewportHeight - 1 - scrollMargin
            var steps = 0
            while cursorVisual() > bottomLimit && steps <= -applied {
                let line = document.cursorLine, col = document.cursorColumn
                if wrapped { moveUpWrapped() } else { document.moveUp() }
                if document.cursorLine == line && document.cursorColumn == col { break }
                steps += 1
            }
        }
        document.clearSelection()
    }

    func setTheme(_ name: ThemeName) {
        themeName = name
        Theme.name = name
        saveConfig()
    }

    func setAppearance(_ appearance: Appearance) {
        self.appearance = appearance
        Theme.mode = appearance.mode
        saveConfig()
    }
    
    private func saveConfig() {
        var config = Config.load()
        config.wordWrap = wordWrap
        config.showLineNumbers = showLineNumbers
        config.statusBarBig = statusBarBig
        config.scrollPastEnd = scrollPastEnd
        config.fullTable = fullTable
        config.contextHelp = contextHelp
        config.blockMode = blockMode
        config.leftMargin = leftMargin
        config.scrollOff = scrollMargin
        config.theme = themeName.rawValue
        config.appearance = appearance.rawValue
        config.renderMarkdown = viewMode == .normal
        config.llmProvider = llmProvider
        config.openRouterKey = openRouterKey
        config.openRouterModel = openRouterModel
        config.openAIAccessToken = openAIAccessToken
        config.openAIRefreshToken = openAIRefreshToken
        config.openAIExpiresAt = openAIExpiresAt
        config.save()
    }

    var openAIIsSignedIn: Bool {
        guard let token = openAIAccessToken else { return false }
        return !token.isEmpty
    }

    func setLLMProvider(_ provider: LLMProvider) {
        llmProvider = provider
        saveConfig()
    }

    func setOpenRouterKey(_ key: String) {
        openRouterKey = key
        saveConfig()
    }

    func setOpenRouterModel(_ model: String) {
        openRouterModel = model
        saveConfig()
    }

    func setOpenAITokens(accessToken: String, refreshToken: String?, expiresAt: Double?) {
        openAIAccessToken = accessToken
        openAIRefreshToken = refreshToken
        openAIExpiresAt = expiresAt
        saveConfig()
    }
    
    func handleCharacter(_ char: Character) {
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
        }
        document.insertCharacter(char)
        isDirty = true
    }
    
    /// Enter, with auto-continuation: inside a list/task/quote it carries the
    /// marker onto the next line; on an empty item it breaks out of the list;
    /// inside a table it adds a blank row. Plain lines split normally.
    func handleNewline() {
        if document.hasSelection {
            saveSnapshot()
            document.deleteSelection()
            document.insertNewline()
            isDirty = true
            return
        }

        // At column 0 (e.g. a block handle) don't auto-continue — just open a
        // line above, so the marker isn't duplicated.
        if document.cursorColumn == 0 {
            saveSnapshot()
            document.insertNewline()
            isDirty = true
            return
        }

        let line = document.cursorLine < document.lines.count ? document.lines[document.cursorLine] : ""
        saveSnapshot()
        switch newlineAction(for: line) {
        case .normal:
            document.insertNewline()
        case .exitList:
            // Empty item: drop the marker and stay on the now-blank line.
            document.lines[document.cursorLine] = ""
            document.cursorColumn = 0
        case .continueList(let prefix):
            document.insertNewline()
            for ch in prefix { document.insertCharacter(ch) }
        case .newTableRow(let row, let cursorCol):
            document.cursorColumn = line.count        // append below, don't split the row
            document.insertNewline()
            for ch in row { document.insertCharacter(ch) }
            document.cursorColumn = min(cursorCol, document.lines[document.cursorLine].count)
        }
        isDirty = true
    }

    private enum NewlineAction {
        case normal
        case exitList
        case continueList(prefix: String)
        case newTableRow(row: String, cursorCol: Int)
    }

    /// Length of the structural prefix (heading hashes, bullet, checkbox, quote
    /// bar) at the start of `line`, i.e. the column where its content begins, or
    /// nil if the line has no such structure. Drives block mode.
    func structuredPrefixLength(of line: String) -> Int? {
        let chars = Array(line)
        // Heading: "# " … "### " (no indentation).
        var h = 0
        while h < chars.count && h < 3 && chars[h] == "#" { h += 1 }
        if h >= 1, h < chars.count, chars[h] == " " { return h + 1 }

        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        // Bullet or task.
        if i < chars.count, "-*+".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " {
            if i + 4 < chars.count, chars[i + 2] == "[", chars[i + 4] == "]" {
                var j = i + 5
                if j < chars.count && chars[j] == " " { j += 1 }
                return j
            }
            return i + 2
        }
        // Blockquote.
        if i < chars.count, chars[i] == ">" {
            var j = i + 1
            if j < chars.count && chars[j] == " " { j += 1 }
            return j
        }
        return nil
    }

    /// True when the cursor sits at the start of a structured line and block mode
    /// is on — the line shows rendered and keys "operate" rather than edit.
    var cursorInBlockHandle: Bool {
        guard blockMode, !document.hasSelection, document.cursorColumn == 0,
              document.cursorLine < document.lines.count else { return false }
        let line = document.lines[document.cursorLine]
        if structuredPrefixLength(of: line) != nil || isThematicBreakLine(line) { return true }
        // A table row (renders inside the bordered grid).
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// A `---` / `***` / `___` thematic break (renders as a horizontal rule).
    private func isThematicBreakLine(_ line: String) -> Bool {
        let s = line.filter { !$0.isWhitespace }
        guard s.count >= 3, let f = s.first, f == "-" || f == "*" || f == "_" else { return false }
        return s.allSatisfy { $0 == f }
    }

    /// Heading level (1–3) of the cursor's line, or nil if it isn't a heading.
    var cursorHeadingLevel: Int? {
        guard document.cursorLine < document.lines.count else { return nil }
        let chars = Array(document.lines[document.cursorLine])
        var n = 0
        while n < chars.count && n < 3 && chars[n] == "#" { n += 1 }
        guard n >= 1, n < chars.count, chars[n] == " " else { return nil }
        return n
    }

    /// Change the cursor line's heading level by `delta` "#" marks, clamped to
    /// 1–3 (the levels editxr renders). `delta < 0` promotes (bigger heading),
    /// `delta > 0` demotes. No-op on non-heading lines.
    func adjustHeadingLevel(by delta: Int) {
        guard let level = cursorHeadingLevel else { return }
        let newLevel = max(1, min(3, level + delta))
        guard newLevel != level else { return }
        saveSnapshot()
        let chars = Array(document.lines[document.cursorLine])
        let content = String(chars[(level + 1)...])
        document.lines[document.cursorLine] = String(repeating: "#", count: newLevel) + " " + content
        let shift = newLevel - level
        document.cursorColumn = max(0, min(document.cursorColumn + shift, document.lines[document.cursorLine].count))
        isDirty = true
    }

    /// True when the cursor's line is a checkbox task (`- [ ] …`). Used to gate
    /// Tab so it only cycles task state, never converts a plain line.
    var cursorLineIsTask: Bool {
        guard document.cursorLine < document.lines.count else { return false }
        let chars = Array(document.lines[document.cursorLine])
        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        guard i < chars.count, "-*+".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " else { return false }
        return i + 4 < chars.count && chars[i + 2] == "[" && chars[i + 4] == "]"
    }

    private func newlineAction(for line: String) -> NewlineAction {
        let chars = Array(line)
        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        let indent = String(chars[0..<i])

        // Bullet or task: "<-|*|+> …", optionally "<-|*|+> [x] …"
        if i < chars.count, "-*+".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " {
            let bullet = chars[i]
            if i + 4 < chars.count, chars[i + 2] == "[", chars[i + 4] == "]" {
                var j = i + 5
                if j < chars.count && chars[j] == " " { j += 1 }
                let content = j < chars.count ? String(chars[j...]) : ""
                return content.trimmingCharacters(in: .whitespaces).isEmpty
                    ? .exitList : .continueList(prefix: "\(indent)\(bullet) [ ] ")
            }
            let content = i + 2 <= chars.count ? String(chars[(i + 2)...]) : ""
            return content.trimmingCharacters(in: .whitespaces).isEmpty
                ? .exitList : .continueList(prefix: "\(indent)\(bullet) ")
        }

        // Blockquote: "> …"
        if i < chars.count, chars[i] == ">" {
            var j = i + 1
            if j < chars.count && chars[j] == " " { j += 1 }
            let content = j < chars.count ? String(chars[j...]) : ""
            return content.trimmingCharacters(in: .whitespaces).isEmpty
                ? .exitList : .continueList(prefix: "\(indent)> ")
        }

        // Table row: "| … | … |" → add a blank row with the same column count.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), trimmed.count > 1 {
            var body = trimmed
            body.removeFirst()
            if body.hasSuffix("|") { body.removeLast() }
            let cells = body.components(separatedBy: "|")
            // A row of only blanks (or no cells) ends the table on Enter.
            if !cells.isEmpty, cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let row = "|" + String(repeating: "  |", count: cells.count)
                return .newTableRow(row: row, cursorCol: 2)
            }
        }

        return .normal
    }
    
    func handleBackspace() {
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
            isDirty = true
        } else {
            document.deleteBackward()
            isDirty = true
        }
    }
    
    func deleteWordBackward() {
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
            isDirty = true
        } else {
            document.deleteWordBackward()
            isDirty = true
        }
    }
    
    func deleteSelection() {
        if document.hasSelection {
            saveSnapshot()
            document.deleteSelection()
            isDirty = true
        }
    }
    
    /// Empty the whole document in memory. The file on disk is untouched until
    /// the next save; undoable like any other edit.
    func clearAll() {
        guard !(document.lines.count == 1 && document.lines[0].isEmpty) else { return }
        saveSnapshot()
        document.lines = [""]
        document.cursorLine = 0
        document.cursorColumn = 0
        document.clearSelection()
        scrollOffset = 0
        scrollX = 0
        isDirty = true
    }

    /// Cycle the task state of the current line (or every line in the selection)
    /// through `[ ]` → `[*]` → `[x]` → `[ ]`. A plain bullet becomes an empty
    /// task; a non-list line becomes a `- [ ]` task.
    func cycleTaskState() {
        let startLine: Int
        let endLine: Int
        if let range = document.selectionRange {
            startLine = range.start.line
            endLine = range.end.line
        } else {
            startLine = document.cursorLine
            endLine = document.cursorLine
        }

        var newLines = document.lines
        var changed = false
        for idx in startLine...endLine where idx < newLines.count {
            let updated = cycledTaskLine(newLines[idx])
            if updated != newLines[idx] {
                newLines[idx] = updated
                changed = true
            }
        }
        guard changed else { return }

        saveSnapshot()
        document.lines = newLines
        if document.cursorLine < document.lines.count {
            document.cursorColumn = min(document.cursorColumn, document.lines[document.cursorLine].count)
        }
        document.clearSelection()
        isDirty = true
    }

    private func cycledTaskLine(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        let indent = String(chars[0..<i])

        // Existing bullet "<-|*|+> ..."
        if i < chars.count, "-*+".contains(chars[i]), i + 1 < chars.count, chars[i + 1] == " " {
            let bullet = chars[i]
            // Existing task "<bullet> [<state>] ..."
            if i + 4 < chars.count, chars[i + 2] == "[", chars[i + 4] == "]" {
                let nextState: Character
                switch chars[i + 3] {
                case " ": nextState = "*"          // empty → in progress
                case "*": nextState = "x"          // in progress → done
                case "x", "X": nextState = " "     // done → empty
                default: return line               // unrecognized box, leave alone
                }
                var out = chars
                out[i + 3] = nextState
                return String(out)
            }
            // Plain bullet → empty task
            let rest = String(chars[(i + 2)...])
            return "\(indent)\(bullet) [ ] \(rest)"
        }

        // Non-list line → empty task
        let rest = String(chars[i...])
        return "\(indent)- [ ] \(rest)"
    }

    /// Copy the selection to the clipboard; returns the number of characters
    /// copied (0 if there's no selection).
    @discardableResult
    func copy() -> Int {
        guard let text = document.selectedText else { return 0 }
        clipboard = text
        SystemClipboard.write(text)
        return text.count
    }

    /// Cut the selection to the clipboard; returns characters removed.
    @discardableResult
    func cut() -> Int {
        guard let text = document.selectedText else { return 0 }
        saveSnapshot()
        clipboard = text
        SystemClipboard.write(text)
        document.deleteSelection()
        isDirty = true
        return text.count
    }

    /// Paste from the clipboard; returns characters inserted.
    @discardableResult
    func paste() -> Int {
        // Prefer the system clipboard so text copied in other apps pastes here;
        // fall back to our own buffer when no clipboard tool is available.
        let text = SystemClipboard.read() ?? clipboard
        guard !text.isEmpty else { return 0 }
        pasteText(text)
        return text.count
    }
    
    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
        }
        for char in text {
            if char == "\n" {
                document.insertNewline()
            } else {
                document.insertCharacter(char)
            }
        }
        isDirty = true
    }
    
    func replaceSelection(with text: String) {
        guard document.hasSelection else { return }
        saveSnapshot()
        document.deleteSelection()
        insertText(text)
        isDirty = true
    }
    
    func replaceParagraph(with text: String) {
        guard let range = document.currentParagraphRange else { return }
        saveSnapshot()
        document.replaceRange(range, with: text)
        isDirty = true
    }

    // MARK: - LLM edit review

    var isReviewing: Bool { pendingEdit != nil }

    /// Enter review for the whole-line range [startLine, endLine] with the
    /// LLM's proposed replacement. Nothing is applied yet — the diff is shown
    /// inline until accept/reject.
    func beginReview(startLine: Int, endLine: Int, proposed: String) {
        guard startLine >= 0, endLine < document.lines.count, startLine <= endLine else { return }
        let original = Array(document.lines[startLine...endLine])
        // Normalize line endings: models often emit CRLF (or bare CR), which
        // would otherwise leave a stray \r in each line (shown as ^M).
        let normalized = proposed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let proposedLines = normalized.components(separatedBy: "\n")
        pendingEdit = PendingEdit(
            startLine: startLine,
            endLine: endLine,
            proposedLines: proposedLines,
            diff: Diff.lines(original, proposedLines))
        document.clearSelection()
        document.cursorLine = startLine
        document.cursorColumn = 0
        scrollOffset = max(0, startLine - 2)
    }

    func acceptPendingEdit() {
        guard let pe = pendingEdit, pe.endLine < document.lines.count else { pendingEdit = nil; return }
        saveSnapshot()
        let range = (start: CursorPosition(line: pe.startLine, column: 0),
                     end: CursorPosition(line: pe.endLine, column: document.lines[pe.endLine].count))
        document.replaceRange(range, with: pe.proposedLines.joined(separator: "\n"))
        pendingEdit = nil
        isDirty = true
    }

    func rejectPendingEdit() {
        pendingEdit = nil
    }
    
    func insertAtCursor(_ text: String) {
        saveSnapshot()
        insertText(text)
        isDirty = true
    }
    
    private func insertText(_ text: String) {
        for char in text {
            if char == "\n" {
                document.insertNewline()
            } else {
                document.insertCharacter(char)
            }
        }
    }
    
    private var lastViewportWidth: Int = 80
    
    func moveUp(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        
        if wordWrap {
            moveUpWrapped()
        } else {
            document.moveUp()
        }
    }
    
    func moveDown(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        
        if wordWrap {
            moveDownWrapped()
        } else {
            document.moveDown()
        }
    }
    
    private func moveUpWrapped() {
        let line = document.currentLineText
        let segments = wrapLineForNavigation(line, width: lastViewportWidth)
        
        var currentSegmentIndex = 0
        var localColumn = document.cursorColumn
        
        for (i, seg) in segments.enumerated() {
            if document.cursorColumn >= seg.startOffset && document.cursorColumn < seg.startOffset + seg.segment.count + 1 {
                currentSegmentIndex = i
                localColumn = document.cursorColumn - seg.startOffset
                break
            }
        }
        
        if currentSegmentIndex > 0 {
            let prevSegment = segments[currentSegmentIndex - 1]
            document.cursorColumn = min(prevSegment.startOffset + localColumn, prevSegment.startOffset + prevSegment.segment.count)
        } else {
            if document.cursorLine > 0 {
                document.cursorLine -= 1
                let prevLine = document.currentLineText
                let prevSegments = wrapLineForNavigation(prevLine, width: lastViewportWidth)
                if let lastSeg = prevSegments.last {
                    document.cursorColumn = min(lastSeg.startOffset + localColumn, prevLine.count)
                }
            }
        }
    }
    
    private func moveDownWrapped() {
        let line = document.currentLineText
        let segments = wrapLineForNavigation(line, width: lastViewportWidth)
        
        var currentSegmentIndex = 0
        var localColumn = document.cursorColumn
        
        for (i, seg) in segments.enumerated() {
            let segEnd = i == segments.count - 1 ? seg.startOffset + seg.segment.count + 1 : seg.startOffset + seg.segment.count
            if document.cursorColumn >= seg.startOffset && document.cursorColumn < segEnd {
                currentSegmentIndex = i
                localColumn = document.cursorColumn - seg.startOffset
                break
            }
        }
        
        if currentSegmentIndex < segments.count - 1 {
            let nextSegment = segments[currentSegmentIndex + 1]
            document.cursorColumn = min(nextSegment.startOffset + localColumn, nextSegment.startOffset + nextSegment.segment.count)
        } else {
            if document.cursorLine < document.lines.count - 1 {
                document.cursorLine += 1
                let nextLine = document.currentLineText
                let nextSegments = wrapLineForNavigation(nextLine, width: lastViewportWidth)
                if let firstSeg = nextSegments.first {
                    document.cursorColumn = min(firstSeg.startOffset + localColumn, nextLine.count)
                }
            }
        }
    }
    
    private func wrapLineForNavigation(_ line: String, width: Int) -> [(segment: String, startOffset: Int)] {
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
    
    func setViewportWidth(_ width: Int) {
        lastViewportWidth = width
    }

    // MARK: - Mouse selection

    /// Start a selection at the document cell under a viewport press. `row` is
    /// 0-based within the text viewport, `col` 0-based within the content area
    /// (right of the gutter). A press with no drag leaves no selection.
    func mousePress(row: Int, col: Int, viewportWidth: Int) {
        let pos = documentPosition(visualRow: row, col: col, viewportWidth: viewportWidth)
        document.cursorLine = pos.line
        document.cursorColumn = pos.column
        document.selectionAnchor = pos
    }

    /// Extend the in-progress mouse selection: move the cursor, keep the anchor.
    func mouseDrag(row: Int, col: Int, viewportWidth: Int) {
        let pos = documentPosition(visualRow: row, col: col, viewportWidth: viewportWidth)
        document.cursorLine = pos.line
        document.cursorColumn = pos.column
    }

    /// Map a viewport cell (visual row from the top of the viewport, column
    /// right of the gutter) to a raw document position. Mirrors the cursor model:
    /// wrapping is computed on the raw line, so positions stay consistent with
    /// keyboard navigation (sub-character precision on collapsed markdown is
    /// approximate, which self-corrects once the line renders raw under the cursor).
    private func documentPosition(visualRow: Int, col: Int, viewportWidth: Int) -> CursorPosition {
        let lineCount = document.lines.count
        guard lineCount > 0 else { return CursorPosition(line: 0, column: 0) }
        let wrapped = wordWrap && pendingEdit == nil && syntaxHighlighter == nil

        if !wrapped {
            let line = min(max(0, scrollOffset + visualRow), lineCount - 1)
            return CursorPosition(line: line, column: rawColumn(in: line, visualCol: col + scrollX))
        }

        // Walk the document's raw-wrapped visual lines from the top.
        let target = scrollOffset + max(0, visualRow)
        var visual = 0
        for li in 0..<lineCount {
            let segs = wrapLineForNavigation(document.lines[li], width: max(1, viewportWidth))
            if target < visual + segs.count {
                let seg = segs[target - visual]
                let isLast = (target - visual) == segs.count - 1
                let maxCol = isLast ? document.lines[li].count : seg.startOffset + seg.segment.count
                let column = min(seg.startOffset + max(0, col), maxCol)
                return CursorPosition(line: li, column: column)
            }
            visual += segs.count
        }
        let last = lineCount - 1
        return CursorPosition(line: last, column: document.lines[last].count)
    }

    /// Convert an on-screen visual column to a raw column on `line`, undoing the
    /// collapse of inline markdown markers. Clamped to the line length.
    private func rawColumn(in line: Int, visualCol: Int) -> Int {
        let text = document.lines[line]
        let spans = MarkdownLineParser.parse(text)
        let raw = MarkdownLineParser.visualToRaw(column: max(0, visualCol), spans: spans)
        return min(max(0, raw), text.count)
    }
    
    func moveLeft(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        
        let line = document.currentLineText
        let spans = MarkdownLineParser.parse(line)
        let cursorInSpan = MarkdownLineParser.spanContainingCursor(column: document.cursorColumn, spans: spans)
        
        if let span = cursorInSpan {
            if document.cursorColumn == span.contentStart {
                document.cursorColumn = span.rawStart
                return
            }
        } else {
            for span in spans {
                if document.cursorColumn == span.rawEnd {
                    document.cursorColumn = span.contentEnd
                    return
                }
            }
        }
        
        document.moveLeft()
    }
    
    func moveRight(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }

        let line = document.currentLineText
        let spans = MarkdownLineParser.parse(line)
        let cursorInSpan = MarkdownLineParser.spanContainingCursor(column: document.cursorColumn, spans: spans)
        
        if let span = cursorInSpan {
            if document.cursorColumn == span.contentEnd - 1 {
                document.cursorColumn = span.rawEnd
                return
            }
        } else {
            for span in spans {
                if document.cursorColumn == span.rawStart {
                    document.cursorColumn = span.contentStart
                    return
                }
            }
        }
        
        document.moveRight()
    }
    
    func moveWordLeft(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        document.moveWordLeft()
    }
    
    func moveWordRight(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        document.moveWordRight()
    }
    
    func adjustScroll(viewportHeight: Int, viewportWidth: Int) {
        // We render non-wrapped while reviewing a diff and for code files, so
        // scrollOffset must be in document-line units there.
        if wordWrap && pendingEdit == nil && syntaxHighlighter == nil {
            adjustScrollWrapped(viewportHeight: viewportHeight, viewportWidth: viewportWidth)
            return
        }
        
        let cursorLine = document.cursorLine
        let cursorColumn = document.cursorColumn
        
        if cursorLine < scrollOffset + scrollMargin {
            scrollOffset = max(0, cursorLine - scrollMargin)
        }
        
        let bottomEdge = scrollOffset + viewportHeight - 1
        if cursorLine > bottomEdge - scrollMargin {
            scrollOffset = cursorLine - viewportHeight + scrollMargin + 1
        }
        
        // scrollPastEnd allows a little blank room below the last line, reached
        // by scrolling — no sudden snap to the middle when the cursor hits the end.
        let endSlack = scrollPastEnd ? viewportHeight / 2 : 0
        let maxScroll = max(0, document.lines.count - viewportHeight + endSlack)
        scrollOffset = min(scrollOffset, maxScroll)

        if cursorColumn < scrollX + scrollMarginX {
            scrollX = max(0, cursorColumn - scrollMarginX)
        }
        
        let rightEdge = scrollX + viewportWidth - 1
        if cursorColumn > rightEdge - scrollMarginX {
            scrollX = cursorColumn - viewportWidth + scrollMarginX + 1
        }
        
        scrollX = max(0, scrollX)
    }
    
    private func adjustScrollWrapped(viewportHeight: Int, viewportWidth: Int) {
        let cursorVisualLine = visualLineForCursor(viewportWidth: viewportWidth)
        
        if cursorVisualLine < scrollOffset + scrollMargin {
            scrollOffset = max(0, cursorVisualLine - scrollMargin)
        }
        
        let bottomEdge = scrollOffset + viewportHeight - 1
        if cursorVisualLine > bottomEdge - scrollMargin {
            scrollOffset = cursorVisualLine - viewportHeight + scrollMargin + 1
        }
        
        let totalVisualLines = countVisualLines(viewportWidth: viewportWidth)
        let endSlack = scrollPastEnd ? viewportHeight / 2 : 0
        let maxScroll = max(0, totalVisualLines - viewportHeight + endSlack)
        scrollOffset = min(scrollOffset, maxScroll)
    }
    
    private func visualLineForCursor(viewportWidth: Int) -> Int {
        var visualLine = 0
        for i in 0..<document.cursorLine {
            visualLine += wrappedLineCount(document.lines[i], width: viewportWidth)
        }
        let currentLine = document.lines[document.cursorLine]
        let segments = wrapLineForNavigation(currentLine, width: viewportWidth)
        var segmentIndex = 0
        for (idx, seg) in segments.enumerated() {
            let segEnd = seg.startOffset + seg.segment.count
            if document.cursorColumn >= seg.startOffset && document.cursorColumn < segEnd {
                segmentIndex = idx
                break
            }
            if idx == segments.count - 1 && document.cursorColumn >= seg.startOffset {
                segmentIndex = idx
            }
        }
        visualLine += segmentIndex
        return visualLine
    }
    
    private func countVisualLines(viewportWidth: Int) -> Int {
        var total = 0
        for line in document.lines {
            total += wrappedLineCount(line, width: viewportWidth)
        }
        return total
    }
    
    private func wrappedLineCount(_ line: String, width: Int) -> Int {
        return wrapLineForNavigation(line, width: width).count
    }
    
    func pageUp(viewportHeight: Int, selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        let pageSize = viewportHeight - scrollMargin
        document.cursorLine = max(0, document.cursorLine - pageSize)
        document.cursorColumn = min(document.cursorColumn, document.currentLineText.count)
        scrollOffset = max(0, scrollOffset - pageSize)
    }

    func pageDown(viewportHeight: Int, selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        let pageSize = viewportHeight - scrollMargin
        document.cursorLine = min(document.lines.count - 1, document.cursorLine + pageSize)
        document.cursorColumn = min(document.cursorColumn, document.currentLineText.count)
        scrollOffset = min(max(0, document.lines.count - viewportHeight), scrollOffset + pageSize)
    }

    /// Select the whole document: anchor at the very start, cursor at the very end.
    func selectAll() {
        guard !document.lines.isEmpty else { return }
        document.selectionAnchor = CursorPosition(line: 0, column: 0)
        let lastLine = document.lines.count - 1
        document.cursorLine = lastLine
        document.cursorColumn = document.lines[lastLine].count
    }

    // MARK: - Find

    /// Open the find bar, anchoring "first match" search to the current cursor.
    func beginSearch() {
        searchActive = true
        searchOrigin = document.cursorPosition
        searchQuery = ""
        searchMatches = []
        searchIndex = 0
    }

    func appendSearchChar(_ char: Character) {
        searchQuery.append(char)
        refreshSearch(jumpFromOrigin: true)
    }

    func backspaceSearch() {
        guard !searchQuery.isEmpty else { return }
        searchQuery.removeLast()
        refreshSearch(jumpFromOrigin: true)
    }

    /// Close the find bar but keep the query/matches so Ctrl+G keeps working.
    func commitSearch() {
        searchActive = false
    }

    /// Abandon the find: clear bar, query, matches, and the match highlight.
    func cancelSearch() {
        searchActive = false
        searchQuery = ""
        searchMatches = []
        searchIndex = 0
        document.clearSelection()
    }

    /// Jump to the next match (wraps). Recomputes against the live document so
    /// edits between presses can't leave a stale index.
    func searchNext() { stepSearch(forward: true) }
    func searchPrevious() { stepSearch(forward: false) }

    private func stepSearch(forward: Bool) {
        guard !searchQuery.isEmpty else { return }
        let matches = computeMatches(searchQuery)
        searchMatches = matches
        guard !matches.isEmpty else { return }
        searchIndex = (searchIndex + (forward ? 1 : -1) + matches.count) % matches.count
        jumpTo(matches[searchIndex])
    }

    /// Recompute matches for the current query; jump to the first match at or
    /// after the search origin (used while typing in the bar).
    private func refreshSearch(jumpFromOrigin: Bool) {
        let matches = computeMatches(searchQuery)
        searchMatches = matches
        guard !matches.isEmpty else {
            searchIndex = 0
            document.clearSelection()
            return
        }
        if jumpFromOrigin {
            searchIndex = matches.firstIndex { m in
                m.line > searchOrigin.line || (m.line == searchOrigin.line && m.column >= searchOrigin.column)
            } ?? 0
        } else {
            searchIndex = min(searchIndex, matches.count - 1)
        }
        jumpTo(matches[searchIndex])
    }

    /// All case-insensitive matches of `query`, in document order. Columns are
    /// Character offsets to match the editor's cursor model.
    private func computeMatches(_ query: String) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        var result: [SearchMatch] = []
        for (li, line) in document.lines.enumerated() {
            var from = line.startIndex
            while let r = line.range(of: query, options: [.caseInsensitive], range: from..<line.endIndex) {
                let col = line.distance(from: line.startIndex, to: r.lowerBound)
                let len = line.distance(from: r.lowerBound, to: r.upperBound)
                result.append(SearchMatch(line: li, column: col, length: len))
                from = r.isEmpty ? line.index(after: r.lowerBound) : r.upperBound
                if from >= line.endIndex { break }
            }
        }
        return result
    }

    /// Move the cursor to a match and select it so it renders highlighted.
    private func jumpTo(_ match: SearchMatch) {
        document.cursorLine = match.line
        document.cursorColumn = match.column + match.length
        document.selectionAnchor = CursorPosition(line: match.line, column: match.column)
    }

    func goToTop() {
        document.cursorLine = 0
        document.cursorColumn = 0
        document.clearSelection()
        scrollOffset = 0
    }

    func goToBottom() {
        document.cursorLine = max(0, document.lines.count - 1)
        document.cursorColumn = min(document.cursorColumn, document.currentLineText.count)
        document.clearSelection()
    }
}
