import Foundation

struct PaletteCommand {
    let title: String
    let shortcut: String
    let action: () -> Void
}

final class CommandPanel {
    enum State {
        case hidden
        case browsing
        case oauth(url: String, message: String)
        case error(String)
    }

    private(set) var state: State = .hidden
    private var commands: [PaletteCommand] = []
    private var query: String = ""
    private var selectedIndex: Int = 0

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
    }

    func show() {
        query = ""
        selectedIndex = 0
        state = .browsing
        onStateChanged?()
    }

    func hide() {
        state = .hidden
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
        case .oauth, .error:
            if char == Key.escape { hide() }
        case .hidden:
            break
        }
    }

    private func handleBrowsingKey(_ char: Character) {
        switch char {
        case Key.escape:
            hide()
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
        cmds[selectedIndex].action()
        // If the action didn't transition the panel into another state
        // (e.g. OAuth), close it after running the command.
        if case .browsing = state {
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

    // Box geometry: "▌" bar (1) + left pad (2) + content + right pad (2).
    private let barWidth = 1
    private let padX = 2

    /// Returns the box positioned on screen. `lines` are the box only (visible
    /// width == `width` field), so the caller can composite them over the document.
    func render(width: Int, height: Int) -> (top: Int, left: Int, width: Int, lines: [String])? {
        guard isVisible else { return nil }
        guard width > 24 && height > 8 else { return nil }

        let boxWidth = min(60, max(40, width - 10))
        let left = max(0, (width - boxWidth) / 2)
        let contentWidth = boxWidth - barWidth - padX * 2

        let (top, lines): (Int, [String])
        switch state {
        case .browsing:
            (top, lines) = renderBrowsing(height: height, boxWidth: boxWidth, contentWidth: contentWidth)
        case .oauth(let url, let message):
            (top, lines) = renderSimple(["Sign in to OpenAI", "", message, url, "", "Esc cancel"],
                                        height: height, boxWidth: boxWidth, contentWidth: contentWidth)
        case .error(let msg):
            (top, lines) = renderSimple(["Error", "", msg, "", "Esc close"],
                                        height: height, boxWidth: boxWidth, contentWidth: contentWidth)
        case .hidden:
            return nil
        }
        return (top: top, left: left, width: boxWidth, lines: lines)
    }

    private func renderBrowsing(height: Int, boxWidth: Int, contentWidth: Int) -> (Int, [String]) {
        let cmds = filteredCommands

        let header = 3   // top pad + search + blank
        let footer = 3   // blank + hint + bottom pad
        let maxRows = max(1, min(cmds.isEmpty ? 1 : cmds.count, height - 4 - header - footer))

        var start = 0
        if selectedIndex >= maxRows {
            start = selectedIndex - maxRows + 1
        }
        let end = min(cmds.count, start + maxRows)
        let shownRows = cmds.isEmpty ? 1 : (end - start)

        let boxHeight = header + shownRows + footer
        let top = max(0, (height - boxHeight) / 2)

        var lines: [String] = []
        lines.append(blankRow(boxWidth: boxWidth))                                              // top pad
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
        lines.append(textRow("↑↓ move   ↵ run   esc close", color: Theme.textMuted, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth))
        lines.append(blankRow(boxWidth: boxWidth))                                              // bottom pad
        return (top, lines)
    }

    private func renderSimple(_ content: [String], height: Int, boxWidth: Int, contentWidth: Int) -> (Int, [String]) {
        var lines = [blankRow(boxWidth: boxWidth)]
        lines += content.map { textRow($0, color: Theme.statusBarText, cursor: false, contentWidth: contentWidth, boxWidth: boxWidth) }
        lines.append(blankRow(boxWidth: boxWidth))
        let top = max(0, (height - lines.count) / 2)
        return (top, lines)
    }

    // MARK: - Row builders (each returns a box-only line of visible width `boxWidth`)

    private func frame(_ innerStyled: String, innerVisible: Int, bg: String, boxWidth: Int) -> String {
        let contentWidth = boxWidth - barWidth - padX * 2
        let trailing = max(0, contentWidth - innerVisible)
        let padded = innerStyled + String(repeating: " ", count: trailing)
        let lpad = String(repeating: " ", count: padX)
        let rpad = String(repeating: " ", count: padX)
        return "\(Theme.accent)▌\(bg)\(lpad)\(padded)\(rpad)\(Theme.reset)"
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
