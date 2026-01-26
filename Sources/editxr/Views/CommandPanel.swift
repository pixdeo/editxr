import Foundation

final class CommandPanel {
    enum State {
        case hidden
        case browsing
        case oauth(url: String, message: String)
        case error(String)
    }
    
    private(set) var state: State = .hidden
    private(set) var selectedProvider: LLMProvider
    private(set) var openAIIsSignedIn: Bool
    
    var onStateChanged: (() -> Void)?
    var onSelectProvider: ((LLMProvider) -> Void)?
    var onRequestOpenAIOAuth: (() -> Void)?
    
    init(selectedProvider: LLMProvider, openAIIsSignedIn: Bool) {
        self.selectedProvider = selectedProvider
        self.openAIIsSignedIn = openAIIsSignedIn
    }
    
    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }

    var isOAuthInProgress: Bool {
        if case .oauth = state { return true }
        return false
    }
    
    func show(selectedProvider: LLMProvider, openAIIsSignedIn: Bool) {
        self.selectedProvider = selectedProvider
        self.openAIIsSignedIn = openAIIsSignedIn
        state = .browsing
        onStateChanged?()
    }
    
    func hide() {
        state = .hidden
        onStateChanged?()
    }
    
    func setOpenAISignedIn(_ signedIn: Bool) {
        openAIIsSignedIn = signedIn
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
    
    func handleKey(_ char: Character) {
        switch char {
        case Key.escape:
            hide()
        case Key.tab:
            toggleProvider()
        case Key.enter:
            activate()
        default:
            break
        }
    }
    
    private func toggleProvider() {
        switch selectedProvider {
        case .lmStudio:
            selectedProvider = .openaiOAuth
        case .openaiOAuth:
            selectedProvider = .lmStudio
        }
        onStateChanged?()
    }
    
    private func activate() {
        switch selectedProvider {
        case .lmStudio:
            onSelectProvider?(.lmStudio)
            hide()
        case .openaiOAuth:
            if openAIIsSignedIn {
                onSelectProvider?(.openaiOAuth)
                hide()
            } else {
                onRequestOpenAIOAuth?()
            }
        }
    }
    
    func render(width: Int, height: Int) -> (top: Int, lines: [String])? {
        guard isVisible else { return nil }
        guard width > 10 && height > 8 else { return nil }
        
        let boxWidth = min(64, max(28, width - 10))
        let boxHeight = 7
        let top = max(0, (height - boxHeight) / 2)
        let leftPad = max(0, (width - boxWidth) / 2)

        func boxLine(_ content: String) -> String {
            let innerWidth = boxWidth - 2
            let trimmed = content.count > innerWidth ? String(content.prefix(innerWidth)) : content
            let padding = String(repeating: " ", count: max(0, innerWidth - trimmed.count))
            let plain = "▌ \(trimmed)\(padding)"
            let styled = "\(Theme.accent)▌\(Theme.statusBarBg)\(Theme.statusBarText) \(trimmed)\(padding)\(Theme.reset)"
            let outerLeft = String(repeating: " ", count: leftPad)
            let outerRight = String(repeating: " ", count: max(0, width - leftPad - plain.count))
            return "\(outerLeft)\(styled)\(outerRight)"
        }
        
        let title = "Commands"
        let providerText: String = {
            switch selectedProvider {
            case .lmStudio: return "Provider: LM Studio"
            case .openaiOAuth: return "Provider: OpenAI (OAuth)"
            }
        }()
        let openAIStatus = "OpenAI: \(openAIIsSignedIn ? "Signed in" : "Not signed in")"
        let hint = selectedProvider == .openaiOAuth && !openAIIsSignedIn
            ? "Enter sign in  Tab switch  Esc close"
            : "Enter apply  Tab switch  Esc close"
        
        var bodyLines: [String] = []
        bodyLines.append(boxLine(title))
        bodyLines.append(boxLine(""))
        bodyLines.append(boxLine(providerText))
        bodyLines.append(boxLine(openAIStatus))
        
        switch state {
        case .oauth(let url, let message):
            bodyLines.append(boxLine(message))
            bodyLines.append(boxLine(url))
        case .error(let msg):
            bodyLines.append(boxLine("Error: \(msg)"))
            bodyLines.append(boxLine(""))
        default:
            bodyLines.append(boxLine(""))
            bodyLines.append(boxLine(hint))
        }
        
        return (top: top, lines: bodyLines.map { padToVisibleWidth($0, width: width) })
    }
    
    private func padToVisibleWidth(_ str: String, width: Int) -> String {
        var count = 0
        var inEscape = false
        for ch in str {
            if ch == "\u{1B}" {
                inEscape = true
            } else if inEscape {
                if ch.isLetter { inEscape = false }
            } else {
                count += 1
            }
        }
        if count >= width { return str }
        return str + String(repeating: " ", count: width - count)
    }
}
