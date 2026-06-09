import Foundation

struct PaletteCommand {
    let title: String
    let shortcut: String
    /// Keep the panel open after running (e.g. live theme preview) instead of
    /// auto-closing like a terminal command.
    var keepsOpen: Bool = false
    let action: () -> Void
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
    private var query: String = ""
    private var selectedIndex: Int = 0
    // Nav stack of parent menus, for submenu push/pop.
    private var stack: [(title: String, commands: [PaletteCommand], query: String, selectedIndex: Int)] = []

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

    func setCommands(_ commands: [PaletteCommand]) {
        self.commands = commands
        self.title = "Commands"
        self.stack = []
    }

    /// Replace the current level's commands in place (keeping title, stack, and
    /// selection) — used to refresh markers after a keep-open action.
    func replaceCommands(_ commands: [PaletteCommand]) {
        self.commands = commands
        onStateChanged?()
    }

    func show() {
        query = ""
        selectedIndex = 0
        stack = []
        state = .browsing
        onStateChanged?()
    }

    func hide() {
        state = .hidden
        stack = []
        onStateChanged?()
    }

    // MARK: - Navigation

    /// Push a submenu, keeping the current level on the stack to return to.
    func push(title: String, commands: [PaletteCommand]) {
        stack.append((self.title, self.commands, query, selectedIndex))
        self.title = title
        self.commands = commands
        query = ""
        selectedIndex = 0
        state = .browsing
        onStateChanged?()
    }

    private func pop() {
        guard let parent = stack.popLast() else { hide(); return }
        title = parent.title
        commands = parent.commands
        query = parent.query
        selectedIndex = parent.selectedIndex
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
        guard !query.isEmpty else { return commands }
        let q = query.lowercased()
        return commands.filter { $0.title.lowercased().contains(q) }
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
        let count = filteredCommands.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        onStateChanged?()
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
                selectedIndex = 0
                onStateChanged?()
            }
        default:
            if isPrintable(char) {
                query.append(char)
                selectedIndex = 0
                onStateChanged?()
            }
        }
    }

    private func activate() {
        let cmds = filteredCommands
        guard selectedIndex >= 0 && selectedIndex < cmds.count else { return }
        let cmd = cmds[selectedIndex]
        let depthBefore = stack.count
        cmd.action()
        // Auto-close only for terminal commands: if the action navigated
        // (pushed a submenu, opened input/OAuth, hid) or asked to stay open
        // (e.g. live theme preview), leave it as-is.
        if case .browsing = state, stack.count == depthBefore, !cmd.keepsOpen {
            hide()
        } else {
            onStateChanged?()
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

    /// Returns the box positioned on screen. `lines` are the box only (visible
    /// width == `width` field), so the caller can composite them over the document.
    func render(width: Int, height: Int) -> (top: Int, left: Int, width: Int, lines: [String])? {
        guard isVisible else { return nil }
        guard width > 24 && height > 8 else { return nil }

        let boxWidth = min(60, max(40, width - 10))
        let left = max(0, (width - boxWidth) / 2)
        let contentWidth = boxWidth - borderWidth * 2 - padX * 2

        let content: [String]
        switch state {
        case .browsing:
            content = renderBrowsing(boxWidth: boxWidth, contentWidth: contentWidth, height: height)
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
        let top = max(0, (height - lines.count) / 2)
        return (top: top, left: left, width: boxWidth, lines: lines)
    }

    private func borderRow(boxWidth: Int, top: Bool) -> String {
        let lead = top ? "╭" : "╰"
        let tail = top ? "╮" : "╯"
        let mid = String(repeating: "─", count: max(0, boxWidth - 2))
        return "\(Theme.accent)\(lead)\(mid)\(tail)\(Theme.reset)"
    }

    private func renderBrowsing(boxWidth: Int, contentWidth: Int, height: Int) -> [String] {
        let cmds = filteredCommands
        let nested = !stack.isEmpty

        let header = 4   // top pad + title + search + blank
        let footer = 3   // blank + hint + bottom pad
        // Leave room for the two border rows plus a small screen margin.
        let maxRows = max(1, min(cmds.isEmpty ? 1 : cmds.count, height - 6 - header - footer))

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

        if cmds.isEmpty {
            lines.append(textRow("No matching commands", color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        } else {
            for i in start..<end {
                lines.append(commandRow(cmds[i], selected: i == selectedIndex, contentWidth: contentWidth, boxWidth: boxWidth))
            }
        }

        lines.append(blankRow(boxWidth: boxWidth))
        lines.append(textRow(hint, color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))                                              // bottom pad
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
        // │ + bg(pad + content + pad) + │  — borders in the accent colour.
        return "\(Theme.accent)│\(bg)\(pad)\(padded)\(pad)\(Theme.accent)│\(Theme.reset)"
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

    private func commandRow(_ cmd: PaletteCommand, selected: Bool, contentWidth: Int, boxWidth: Int) -> String {
        let shortcut = cmd.shortcut
        let titleAvail = max(1, contentWidth - (shortcut.isEmpty ? 0 : shortcut.displayWidth + 1))
        let title = truncate(cmd.title, to: titleAvail)
        let gap = max(1, contentWidth - title.displayWidth - shortcut.displayWidth)
        let gapSpaces = String(repeating: " ", count: gap)

        let bg = selected ? Theme.selectionBg : Theme.statusBarBg
        let titleColor = selected ? Theme.selectionFg : Theme.statusBarText
        let shortcutColor = selected ? Theme.selectionFg : Theme.textMuted
        let styled = "\(titleColor)\(title)\(gapSpaces)\(shortcutColor)\(shortcut)"
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
