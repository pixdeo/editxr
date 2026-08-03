import Foundation

/// A detail-pane line that already carries its styling. Escape sequences make
/// `String.count` meaningless, so the visible column count travels with it.
struct PreviewLine {
    let styled: String
    let width: Int

    static func plain(_ text: String) -> PreviewLine {
        PreviewLine(styled: text, width: text.displayWidth)
    }
}

struct PaletteCommand {
    let title: String
    let shortcut: String
    /// Keep the panel open after running (e.g. live theme preview) instead of
    /// auto-closing like a terminal command.
    var keepsOpen: Bool = false
    /// Non-selectable section label that breaks the list into groups. Skipped by
    /// arrow navigation and hidden while a search query is active.
    var isHeader: Bool = false
    /// Non-selectable blank row used to separate groups. Like a header, it's
    /// skipped by navigation and hidden during search.
    var isSpacer: Bool = false
    /// If set, activating this row opens a submenu. The closure regenerates the
    /// child commands on demand, so the panel can also flatten them for a global
    /// search across levels and refresh live markers.
    var submenu: (() -> [PaletteCommand])? = nil
    /// Detail-pane content for this row, produced on demand while it is selected
    /// and fitted to the pane width it is handed. Only wide levels (live search)
    /// draw it; everywhere else it is ignored.
    var preview: ((Int) -> [PreviewLine])? = nil
    /// Words this row matched, marked in the title so a hit shows *why* it is a
    /// hit — the reason is often a word the query only reached through a repair
    /// (an accent dropped, a typo, two words run together).
    var matches: [TextMatch] = []
    let action: () -> Void

    /// Whether arrow navigation / activation can land on this row.
    var isSelectable: Bool { !isHeader && !isSpacer }

    /// A group divider row, e.g. `.header("Edit")`.
    static func header(_ title: String) -> PaletteCommand {
        PaletteCommand(title: title, shortcut: "", isHeader: true, action: {})
    }

    /// A blank gap between groups.
    static let spacer = PaletteCommand(title: "", shortcut: "", isSpacer: true, action: {})
}

final class CommandPanel {
    struct InputField {
        let prompt: String
        var value: String
        let isSecret: Bool
        let onSubmit: (String) -> Void
    }

    enum State {
        case hidden
        case browsing
        case input(InputField)
        case oauth(url: String, message: String)
        case error(String)
    }

    private(set) var state: State = .hidden
    private var title: String = "Commands"
    private var commands: [PaletteCommand] = []
    /// Regenerates the current level's commands (fresh state labels / markers).
    private var generate: () -> [PaletteCommand] = { [] }
    private var query: String = ""
    private var selectedIndex: Int = 0
    /// When set, typing runs this instead of fuzzy-filtering `commands`: the
    /// provider returns the rows for the current query. Vault search needs it
    /// because its candidates are the whole index, not a fixed row list.
    private var liveQuery: ((String) -> [PaletteCommand])?
    /// Rows for the last live query. `filteredCommands` is read several times per
    /// keystroke (selection, activation, render), and the provider shouldn't run
    /// once per read.
    private var liveCache: (query: String, rows: [PaletteCommand])?
    /// Detail-pane lines for the current selection, keyed by query + row.
    private var previewCache: (key: String, lines: [PreviewLine])?

    /// Levels that spread across the screen and can show a detail pane. Live
    /// search is the only one today.
    private var isWideLevel: Bool { liveQuery != nil }
    // Nav stack of parent menus, for submenu push/pop.
    private var stack: [(title: String, generate: () -> [PaletteCommand], commands: [PaletteCommand], query: String, selectedIndex: Int, live: ((String) -> [PaletteCommand])?)] = []

    var onStateChanged: (() -> Void)?

    init() {}

    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }

    var isOAuthInProgress: Bool {
        if case .oauth = state { return true }
        return false
    }

    /// Set the root level from a generator so the panel can rebuild it (for live
    /// marker refresh and to flatten nested submenus during a global search).
    func setRoot(title: String = "Commands", generate: @escaping () -> [PaletteCommand]) {
        self.generate = generate
        self.commands = generate()
        self.title = title
        self.stack = []
        self.liveQuery = nil
        self.liveCache = nil
    }

    /// Set the root to a live-search level: every keystroke re-runs `query` and
    /// the rows it returns replace the list. Otherwise it behaves like any other
    /// browsing level — arrows move, Enter activates, Esc closes.
    func setLiveRoot(title: String, query provider: @escaping (String) -> [PaletteCommand]) {
        self.generate = { [] }
        self.commands = []
        self.title = title
        self.stack = []
        self.liveQuery = provider
        self.liveCache = nil
        self.query = ""
        self.state = .browsing
        resetSelection()
        onStateChanged?()
    }

    func show() {
        query = ""
        stack = []
        state = .browsing
        resetSelection()
        onStateChanged?()
    }

    func hide() {
        state = .hidden
        stack = []
        liveQuery = nil
        liveCache = nil
        onStateChanged?()
    }

    // MARK: - Navigation

    /// Push a submenu, keeping the current level on the stack to return to.
    func push(title: String, generate: @escaping () -> [PaletteCommand]) {
        stack.append((self.title, self.generate, self.commands, query, selectedIndex, liveQuery))
        self.title = title
        self.generate = generate
        self.commands = generate()
        query = ""
        liveQuery = nil          // a submenu is a normal fuzzy-filtered level
        liveCache = nil
        state = .browsing
        resetSelection()
        onStateChanged?()
    }

    private func pop() {
        guard let parent = stack.popLast() else { hide(); return }
        title = parent.title
        generate = parent.generate
        commands = parent.commands
        query = parent.query
        selectedIndex = parent.selectedIndex
        liveQuery = parent.live
        liveCache = nil
        state = .browsing
        onStateChanged?()
    }

    /// Switch the current level into a single-field text input.
    func beginInput(prompt: String, value: String, isSecret: Bool, onSubmit: @escaping (String) -> Void) {
        state = .input(InputField(prompt: prompt, value: value, isSecret: isSecret, onSubmit: onSubmit))
        onStateChanged?()
    }

    func setOAuthStatus(url: String, message: String) {
        state = .oauth(url: url, message: message)
        onStateChanged?()
    }

    func setError(_ message: String) {
        state = .error(message)
        onStateChanged?()
    }

    private var filteredCommands: [PaletteCommand] {
        if let liveQuery {
            if let cached = liveCache, cached.query == query { return cached.rows }
            let rows = liveQuery(query)
            liveCache = (query, rows)
            return rows
        }
        guard !query.isEmpty else { return commands }
        // While searching, flatten the whole subtree (descending into submenus)
        // so a command nested a level down still shows up and runs in place.
        // Fuzzy subsequence match + ranking, so "blomo" finds "Toggle block mode".
        let scored = flattenForSearch(commands).enumerated().compactMap { (idx, cmd) -> (cmd: PaletteCommand, score: Int, idx: Int)? in
            guard let s = Self.fuzzyScore(query: query, in: cmd.title) else { return nil }
            return (cmd, s, idx)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.idx < $1.idx }.map { $0.cmd }
    }

    /// Score a fuzzy (subsequence) match of `query` against `title`, or nil if
    /// the query chars don't all appear in order. Higher is better: consecutive
    /// runs and word-start hits score more, so the tightest match floats up.
    static func fuzzyScore(query: String, in title: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(title.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0
        var score = 0
        var lastHit = -2
        for (ti, ch) in t.enumerated() {
            guard qi < q.count, ch == q[qi] else { continue }
            if q[qi] == " " { score += 1; lastHit = ti; qi += 1; continue }
            score += (ti == lastHit + 1) ? 6 : 1          // reward consecutive runs
            if ti == 0 || t[ti - 1] == " " { score += 4 } // reward word starts
            lastHit = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }

    /// Depth-first list of the selectable rows in `cmds` and every submenu they
    /// open. Used only for search; headers / spacers are dropped.
    private func flattenForSearch(_ cmds: [PaletteCommand]) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        for c in cmds where c.isSelectable {
            out.append(c)
            if let sub = c.submenu {
                out.append(contentsOf: flattenForSearch(sub()))
            }
        }
        return out
    }

    /// First selectable row at or after `from`, scanning in the direction of
    /// `step` and wrapping around. Nil if there's nothing to land on.
    private func selectableIndex(from: Int, step: Int) -> Int? {
        let cmds = filteredCommands
        guard !cmds.isEmpty else { return nil }
        var i = from
        for _ in 0..<cmds.count {
            let wrapped = ((i % cmds.count) + cmds.count) % cmds.count
            if cmds[wrapped].isSelectable { return wrapped }
            i += step
        }
        return nil   // nothing selectable
    }

    /// Park the selection on the first selectable row (used after the list or
    /// the search query changes).
    private func resetSelection() {
        selectedIndex = selectableIndex(from: 0, step: 1) ?? 0
    }

    /// Enter / run the selected command (right arrow, mirrors Enter).
    func activateSelected() {
        guard case .browsing = state else { return }
        activate()
    }

    /// Step back one submenu level (left arrow). No-op at the root so it can't
    /// accidentally close the panel.
    func goBack() {
        guard case .browsing = state, !stack.isEmpty else { return }
        pop()
    }

    func moveSelection(_ delta: Int) {
        guard case .browsing = state else { return }
        guard !filteredCommands.isEmpty else { return }
        let step = delta >= 0 ? 1 : -1
        if let idx = selectableIndex(from: selectedIndex + delta, step: step) {
            selectedIndex = idx
            onStateChanged?()
        }
    }

    func handleKey(_ char: Character) {
        switch state {
        case .browsing:
            handleBrowsingKey(char)
        case .input:
            handleInputKey(char)
        case .oauth, .error:
            if char == Key.escape { hide() }
        case .hidden:
            break
        }
    }

    /// Leave the input field back to its menu, clearing the stale search query
    /// so subsequent filtering starts fresh.
    private func returnToMenu() {
        query = ""
        selectedIndex = 0
        state = .browsing
        onStateChanged?()
    }

    private func handleInputKey(_ char: Character) {
        guard case .input(var field) = state else { return }
        switch char {
        case Key.escape:
            returnToMenu()              // cancel: back to the same menu level
        case Key.enter:
            field.onSubmit(field.value)
            returnToMenu()              // return to the (unchanged) menu level
        case Key.backspace:
            if !field.value.isEmpty {
                field.value.removeLast()
                state = .input(field)
                onStateChanged?()
            }
        default:
            if isPrintable(char) {
                field.value.append(char)
                state = .input(field)
                onStateChanged?()
            }
        }
    }

    private func handleBrowsingKey(_ char: Character) {
        switch char {
        case Key.escape:
            pop()                       // back one level, or close at the root
        case Key.enter:
            activate()
        case Key.backspace:
            if !query.isEmpty {
                query.removeLast()
                resetSelection()
                onStateChanged?()
            }
        default:
            if isPrintable(char) {
                query.append(char)
                resetSelection()
                onStateChanged?()
            }
        }
    }

    private func activate() {
        let cmds = filteredCommands
        guard selectedIndex >= 0 && selectedIndex < cmds.count else { return }
        let cmd = cmds[selectedIndex]
        guard cmd.isSelectable else { return }   // headers / spacers aren't actionable

        // Submenu entry: descend into it (works the same whether reached by
        // browsing or matched by a global search).
        if let submenu = cmd.submenu {
            push(title: cmd.title, generate: submenu)
            return
        }

        let depthBefore = stack.count
        cmd.action()
        // If the action navigated (pushed a submenu, opened input/OAuth, hid),
        // leave it. Keep-open commands refresh the level in place so labels /
        // markers update — even when the toggle was reached via search, where
        // re-generating rebuilds the flattened result list. Everything else is a
        // terminal command and closes the panel.
        guard case .browsing = state, stack.count == depthBefore else {
            onStateChanged?()
            return
        }
        if cmd.keepsOpen {
            commands = generate()
            onStateChanged?()
        } else {
            hide()
        }
    }

    private func isPrintable(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let value = scalar.value
        if value < 32 { return false }
        if value == 127 { return false }
        return true
    }

    // MARK: - Rendering

    // Box geometry: "│" border (1) + left pad (2) + content + right pad (2) + "│" border (1).
    private let borderWidth = 1
    private let padX = 2
    /// Screen columns kept clear on each side of a wide level. Must stay above 2
    /// so the drop shadow drawn to the right of the box still lands on screen.
    private static let wideMargin = 4
    /// Columns the " │ " separator takes between the two split columns.
    private static let gutterWidth = 3
    /// Rows kept clear under a wide level: one screen margin plus the row the
    /// drop shadow lands on.
    private static let wideBottomMargin = 2

    /// Fixed top row for a wide level. Sitting a little above centre reads as a
    /// search field rather than a dialog, and never moves.
    static func wideTop(height: Int) -> Int {
        max(2, height / 8)
    }

    /// Content rows a wide level always draws, however many results there are.
    /// Constant per terminal size: a box that resized on every keystroke is what
    /// made the previous layout unusable.
    static func wideContentRows(height: Int) -> Int {
        let chrome = 4 + 3 + 2   // header rows + footer rows + the two borders
        return max(1, height - wideTop(height: height) - wideBottomMargin - chrome)
    }

    /// Returns the box positioned on screen. `lines` are the box only (visible
    /// width == `width` field), so the caller can composite them over the document.
    func render(width: Int, height: Int) -> (top: Int, left: Int, width: Int, lines: [String])? {
        guard isVisible else { return nil }
        guard width > 24 && height > 8 else { return nil }

        // A live-search level spreads to the screen, keeping a margin wide enough
        // for the drop shadow; ordinary menus stay a narrow centred box.
        let wide = isWideLevel && width >= 80 && height >= 20
        let boxWidth = wide ? max(40, width - Self.wideMargin * 2)
                            : min(60, max(40, width - 10))
        let left = max(0, (width - boxWidth) / 2)
        let contentWidth = boxWidth - borderWidth * 2 - padX * 2

        let content: [String]
        switch state {
        case .browsing:
            content = renderBrowsing(boxWidth: boxWidth, contentWidth: contentWidth,
                                     height: height, wide: wide)
        case .input(let field):
            content = renderInput(field, boxWidth: boxWidth, contentWidth: contentWidth)
        case .oauth(let url, let message):
            content = renderSimple(["Sign in to OpenAI", "", message, url, "", "Esc cancel"],
                                   boxWidth: boxWidth, contentWidth: contentWidth)
        case .error(let msg):
            content = renderSimple(["Error", "", msg, "", "Esc close"],
                                   boxWidth: boxWidth, contentWidth: contentWidth)
        case .hidden:
            return nil
        }

        // Wrap the content rows in a rounded border.
        let lines = [borderRow(boxWidth: boxWidth, top: true)] + content + [borderRow(boxWidth: boxWidth, top: false)]
        // A wide level is anchored near the top like Spotlight: the search field
        // must not shift as results come and go. Everything else stays centred.
        let top = wide ? Self.wideTop(height: height)
                       : max(0, (height - lines.count) / 2)
        return (top: top, left: left, width: boxWidth, lines: lines)
    }

    private func borderRow(boxWidth: Int, top: Bool) -> String {
        let lead = top ? "╭" : "╰"
        let tail = top ? "╮" : "╯"
        let mid = String(repeating: "─", count: max(0, boxWidth - 2))
        return "\(Theme.accent)\(lead)\(mid)\(tail)\(Theme.reset)"
    }

    private func renderBrowsing(boxWidth: Int, contentWidth: Int, height: Int, wide: Bool) -> [String] {
        let cmds = filteredCommands
        let nested = !stack.isEmpty

        let header = 4   // top pad + title + search + blank
        let footer = 3   // blank + hint + bottom pad

        // Split geometry: results on the left, the selected note on the right.
        // Below the threshold the detail pane would squeeze both columns, so the
        // level falls back to the ordinary single-column list.
        let split = wide && contentWidth >= 72
        let listWidth = split ? max(32, min(contentWidth * 45 / 100, 64)) : contentWidth
        let previewWidth = split ? contentWidth - listWidth - Self.gutterWidth : 0

        // A wide level reserves the same rows every keystroke and pads the gap;
        // a narrow menu still shrinks to its content.
        let maxRows: Int
        if wide {
            maxRows = Self.wideContentRows(height: height)
        } else {
            let available = max(1, height - 6 - header - footer)
            maxRows = max(1, min(cmds.isEmpty ? 1 : cmds.count, available))
        }
        let preview = split ? previewLines(width: previewWidth, limit: maxRows) : []

        var start = 0
        if selectedIndex >= maxRows {
            start = selectedIndex - maxRows + 1
        }
        let end = min(cmds.count, start + maxRows)

        let hint = nested ? "↑↓ move   ↵ select   esc back" : "↑↓ move   ↵ run   esc close"

        var lines: [String] = []
        lines.append(blankRow(boxWidth: boxWidth))                                              // top pad
        lines.append(textRow(title, color: Theme.accent, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(textRow("Search: \(query)", color: Theme.statusBarText, cursor: true, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))

        if !split {
            if cmds.isEmpty {
                lines.append(textRow("No matching commands", color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
            } else {
                for i in start..<end {
                    lines.append(listRow(cmds[i], selected: i == selectedIndex,
                                         contentWidth: contentWidth, boxWidth: boxWidth))
                }
            }
        } else {
            for row in 0..<maxRows {
                let i = start + row
                let cell: (styled: String, bg: String) = i < end
                    ? listCell(cmds[i], selected: i == selectedIndex, width: listWidth)
                    : (String(repeating: " ", count: listWidth), Theme.statusBarBg)
                let detail = row < preview.count ? preview[row] : PreviewLine.plain("")
                lines.append(splitRow(left: cell.styled, leftBg: cell.bg,
                                      right: detail, rightWidth: previewWidth,
                                      contentWidth: contentWidth, boxWidth: boxWidth))
            }
        }

        lines.append(blankRow(boxWidth: boxWidth))
        lines.append(textRow(hint, color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))                                              // bottom pad
        return lines
    }

    /// One full-width list row: spacer, header, or command.
    private func listRow(_ cmd: PaletteCommand, selected: Bool, contentWidth: Int, boxWidth: Int) -> String {
        if cmd.isSpacer { return blankRow(boxWidth: boxWidth) }
        if cmd.isHeader { return headerRow(cmd.title, contentWidth: contentWidth, boxWidth: boxWidth) }
        return commandRow(cmd, selected: selected, contentWidth: contentWidth, boxWidth: boxWidth)
    }

    /// Detail-pane lines for the selected row, padded/truncated to `width`.
    /// Cached per (query, selection) so moving the cursor doesn't re-read the
    /// note on every repaint.
    private func previewLines(width: Int, limit: Int) -> [PreviewLine] {
        let cmds = filteredCommands
        guard selectedIndex >= 0, selectedIndex < cmds.count,
              let provider = cmds[selectedIndex].preview else { return [] }

        let key = "\(query)\u{0}\(selectedIndex)\u{0}\(width)\u{0}\(limit)"
        if let cached = previewCache, cached.key == key { return cached.lines }

        let lines = Array(provider(width).prefix(limit))
        previewCache = (key, lines)
        return lines
    }

    private func renderInput(_ field: InputField, boxWidth: Int, contentWidth: Int) -> [String] {
        let shown = field.isSecret ? String(repeating: "•", count: field.value.count) : field.value
        var lines: [String] = []
        lines.append(blankRow(boxWidth: boxWidth))
        lines.append(textRow(field.prompt, color: Theme.accent, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))
        lines.append(textRow(shown, color: Theme.statusBarText, cursor: true, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))
        lines.append(textRow("↵ save   esc cancel", color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))
        return lines
    }

    private func renderSimple(_ content: [String], boxWidth: Int, contentWidth: Int) -> [String] {
        var lines = [blankRow(boxWidth: boxWidth)]
        lines += content.map { textRow($0, color: Theme.statusBarText, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth) }
        lines.append(blankRow(boxWidth: boxWidth))
        return lines
    }

    // MARK: - Row builders (each returns a box-only line of visible width `boxWidth`)

    private func frame(_ innerStyled: String, innerVisible: Int, bg: String, boxWidth: Int) -> String {
        let contentWidth = boxWidth - borderWidth * 2 - padX * 2
        let trailing = max(0, contentWidth - innerVisible)
        let padded = innerStyled + String(repeating: " ", count: trailing)
        let pad = String(repeating: " ", count: padX)
        // │ + bg(pad + content + pad) + │  — borders in the accent colour. Reset
        // to the panel bg before the right border so a selected row's highlight
        // stops at the inner edge instead of bleeding over the vertical border.
        return "\(Theme.accent)│\(bg)\(pad)\(padded)\(pad)\(Theme.statusBarBg)\(Theme.accent)│\(Theme.reset)"
    }

    private func blankRow(boxWidth: Int) -> String {
        return frame("", innerVisible: 0, bg: Theme.statusBarBg, boxWidth: boxWidth)
    }

    private func textRow(_ content: String, color: String, cursor: Bool, contentWidth: Int, boxWidth: Int) -> String {
        let text = truncate(content, to: cursor ? contentWidth - 1 : contentWidth)
        var styled = "\(color)\(text)"
        var visible = text.displayWidth
        if cursor && visible < contentWidth {
            styled += "\(Theme.inverse) \(Theme.reset)\(Theme.statusBarBg)"
            visible += 1
        }
        return frame(styled, innerVisible: visible, bg: Theme.statusBarBg, boxWidth: boxWidth)
    }

    private func headerRow(_ title: String, contentWidth: Int, boxWidth: Int) -> String {
        let label = truncate(title.uppercased(), to: contentWidth)
        let styled = "\(Theme.textMuted)\(label)"
        return frame(styled, innerVisible: label.displayWidth, bg: Theme.statusBarBg, boxWidth: boxWidth)
    }

    /// A list cell for the split layout: exactly `width` visible columns of
    /// styled text, plus the background the whole cell (and its padding) uses.
    private func listCell(_ cmd: PaletteCommand, selected: Bool, width: Int) -> (styled: String, bg: String) {
        if cmd.isSpacer {
            return (String(repeating: " ", count: width), Theme.statusBarBg)
        }
        if cmd.isHeader {
            let label = truncate(cmd.title.uppercased(), to: width)
            let pad = String(repeating: " ", count: max(0, width - label.displayWidth))
            return ("\(Theme.textMuted)\(label)\(pad)", Theme.statusBarBg)
        }
        let shortcut = cmd.shortcut
        let titleAvail = max(1, width - (shortcut.isEmpty ? 0 : shortcut.displayWidth + 1))
        let title = truncate(cmd.title, to: titleAvail)
        let minGap = shortcut.isEmpty ? 0 : 1
        let gap = max(minGap, width - title.displayWidth - shortcut.displayWidth)
        let bg = selected ? Theme.selectionBg : Theme.statusBarBg
        let titleColor = selected ? Theme.selectionFg : Theme.statusBarText
        let shortcutColor = selected ? Theme.selectionFg : Theme.textMuted
        let marked = CommandPanel.markMatches(title, cmd: cmd, base: "\(bg)\(titleColor)", selected: selected)
        let styled = "\(titleColor)\(marked)\(String(repeating: " ", count: gap))\(shortcutColor)\(shortcut)"
        // The cell must fill its column exactly, or the separator drifts.
        let overflow = title.displayWidth + gap + shortcut.displayWidth
        let tail = String(repeating: " ", count: max(0, width - overflow))
        return (styled + tail, bg)
    }

    /// Mark the words a row matched. An unmatched row is untouched, so this
    /// costs nothing outside the search panel.
    ///
    /// The mark wears the selection's colours on an ordinary row; on the
    /// selected row — which already wears them — it swaps back to the panel
    /// background, so the word stands out the same way either side of the
    /// highlight.
    static func markMatches(_ text: String, cmd: PaletteCommand, base: String, selected: Bool) -> String {
        guard !cmd.matches.isEmpty else { return text }
        let style = selected
            ? "\(Theme.statusBarBg)\(Theme.accent)\(Theme.bold)"
            : "\(Theme.selectionBg)\(Theme.selectionFg)"
        return MatchHighlighter.mark(text, matches: cmd.matches, base: base, style: style)
    }

    /// A results row beside its detail pane, separated by a muted rule. The
    /// selection highlight stops at the separator so the note stays readable.
    private func splitRow(left: String, leftBg: String,
                          right: PreviewLine, rightWidth: Int,
                          contentWidth: Int, boxWidth: Int) -> String {
        let detailPad = String(repeating: " ", count: max(0, rightWidth - right.width))
        let inner = "\(left)"
            + "\(Theme.statusBarBg)\(Theme.textMuted) │ "
            + "\(Theme.statusBarText)\(right.styled)\(Theme.statusBarBg)\(detailPad)"
        return frame(inner, innerVisible: contentWidth, bg: leftBg, boxWidth: boxWidth)
    }

    private func commandRow(_ cmd: PaletteCommand, selected: Bool, contentWidth: Int, boxWidth: Int) -> String {
        let shortcut = cmd.shortcut
        let titleAvail = max(1, contentWidth - (shortcut.isEmpty ? 0 : shortcut.displayWidth + 1))
        let title = truncate(cmd.title, to: titleAvail)
        // A row with no shortcut needs no trailing gap; forcing one here would
        // push a full-width title a column past the border (ragged right edge).
        let minGap = shortcut.isEmpty ? 0 : 1
        let gap = max(minGap, contentWidth - title.displayWidth - shortcut.displayWidth)
        let gapSpaces = String(repeating: " ", count: gap)

        let bg = selected ? Theme.selectionBg : Theme.statusBarBg
        let titleColor = selected ? Theme.selectionFg : Theme.statusBarText
        let shortcutColor = selected ? Theme.selectionFg : Theme.textMuted
        let marked = CommandPanel.markMatches(title, cmd: cmd, base: "\(bg)\(titleColor)", selected: selected)
        let styled = "\(titleColor)\(marked)\(gapSpaces)\(shortcutColor)\(shortcut)"
        let visible = title.displayWidth + gap + shortcut.displayWidth
        return frame(styled, innerVisible: visible, bg: bg, boxWidth: boxWidth)
    }

    private func truncate(_ s: String, to maxWidth: Int) -> String {
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
}
