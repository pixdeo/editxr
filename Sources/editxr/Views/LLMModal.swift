import Foundation

enum LLMModalState {
    case hidden
    case inputting
    case processing
    case streaming(String)
    case result(String)
    case error(String)
}

class LLMModal {
    private let llmService: LLMService
    private(set) var state: LLMModalState = .hidden
    private(set) var inputBuffer: String = ""
    private(set) var streamedContent: String = ""
    private var contextText: String = ""
    
    var onStateChanged: (() -> Void)?
    
    init(llmService: LLMService) {
        self.llmService = llmService
    }
    
    var isVisible: Bool {
        if case .hidden = state { return false }
        return true
    }
    
    func show(withContext context: String) {
        contextText = context
        inputBuffer = ""
        streamedContent = ""
        state = .inputting
        onStateChanged?()
    }
    
    func hide() {
        llmService.cancel()
        state = .hidden
        inputBuffer = ""
        streamedContent = ""
        contextText = ""
        onStateChanged?()
    }
    
    func handleCharacter(_ char: Character) {
        guard case .inputting = state else { return }
        
        guard let scalar = char.unicodeScalars.first else { return }
        let value = scalar.value
        if value >= 32 && value != 127 {
            inputBuffer.append(char)
            onStateChanged?()
        }
    }
    
    func handleBackspace() {
        guard case .inputting = state else { return }
        if !inputBuffer.isEmpty {
            inputBuffer.removeLast()
            onStateChanged?()
        }
    }
    
    func handleEnter() {
        guard case .inputting = state else { return }
        guard !inputBuffer.isEmpty else { return }
        
        submit()
    }
    
    func handleTab() -> Bool {
        if case .result = state {
            return true
        }
        return false
    }
    
    func handleEscape() {
        switch state {
        case .inputting, .error:
            hide()
        case .processing, .streaming:
            llmService.cancel()
            state = .inputting
            onStateChanged?()
        case .result:
            hide()
        case .hidden:
            break
        }
    }
    
    func getResult() -> String? {
        if case .result(let text) = state {
            return text
        }
        return nil
    }
    
    func acceptResult() -> String? {
        guard let result = getResult() else { return nil }
        hide()
        return result
    }
    
    func render(width: Int) -> [String] {
        guard isVisible else { return [] }
        
        let bg = Theme.statusBarBg
        let fg = Theme.statusBarText
        
        var lines: [String] = []
        
        switch state {
        case .inputting:
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            let label = "Input:"
            lines.append("\(bg)\(fg)\(label)\(String(repeating: " ", count: width - label.count))\(Theme.reset)")
            let cursorVisible = 1
            let textLen = inputBuffer.count
            let totalVisible = textLen + cursorVisible
            let padding = max(0, width - totalVisible)
            let cursor = "\(Theme.inverse) \(Theme.reset)"
            lines.append("\(bg)\(fg)\(inputBuffer)\(cursor)\(bg)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .processing:
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let idx = Int(Date().timeIntervalSince1970 * 10) % spinner.count
            let text = "\(spinner[idx]) Processing..."
            let padding = max(0, width - text.count)
            lines.append("\(bg)\(Theme.accent)\(text)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .streaming(let partial):
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            let displayText = truncateToWidth(partial.replacingOccurrences(of: "\n", with: " "), width: width)
            let visLen = visibleLength(displayText)
            let padding = max(0, width - visLen)
            lines.append("\(bg)\(fg)\(displayText)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .result(let text):
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            let displayText = truncateToWidth(text.replacingOccurrences(of: "\n", with: " "), width: width)
            let visLen = visibleLength(displayText)
            let padding = max(0, width - visLen)
            lines.append("\(bg)\(Theme.accent)\(displayText)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .error(let message):
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            lines.append("\(bg)\(String(repeating: " ", count: width))\(Theme.reset)")
            let text = "⚠ \(message)"
            let displayText = truncateToWidth(text, width: width)
            let visLen = visibleLength(displayText)
            let padding = max(0, width - visLen)
            lines.append("\(bg)\(fg)\(displayText)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .hidden:
            return []
        }
        
        lines.append(renderHintsLine(width: width))
        
        return lines
    }
    
    private func renderHintsLine(width: Int) -> String {
        let bg = Theme.statusBarBg
        let hints: String
        switch state {
        case .inputting:
            hints = "\(Theme.accent)Enter\(Theme.statusBarText) send  \(Theme.accent)Esc\(Theme.statusBarText) cancel"
        case .processing, .streaming:
            hints = "\(Theme.accent)Esc\(Theme.statusBarText) cancel"
        case .result:
            hints = "\(Theme.accent)Tab\(Theme.statusBarText) accept  \(Theme.accent)Esc\(Theme.statusBarText) reject"
        case .error:
            hints = "\(Theme.accent)Esc\(Theme.statusBarText) dismiss"
        case .hidden:
            hints = ""
        }
        
        let hintsLen = visibleLength(hints)
        let padding = max(0, width - hintsLen)
        return "\(bg)\(hints)\(String(repeating: " ", count: padding))\(Theme.reset)"
    }
    
    private func submit() {
        state = .processing
        streamedContent = ""
        onStateChanged?()
        
        llmService.completeStreaming(
            prompt: inputBuffer,
            context: contextText,
            onChunk: { [weak self] chunk in
                guard let self = self else { return }
                self.streamedContent += chunk
                
                if let result = self.extractAfterThink(self.streamedContent) {
                    self.state = .streaming(result)
                }
                self.onStateChanged?()
            },
            onComplete: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    let finalResult = self.extractAfterThink(self.streamedContent) ?? self.streamedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.state = .result(finalResult)
                case .failure(let error):
                    if case .cancelled = error {
                        self.state = .inputting
                    } else {
                        self.state = .error(error.localizedDescription)
                    }
                }
                self.onStateChanged?()
            }
        )
    }
    
    private func extractAfterThink(_ text: String) -> String? {
        if let endRange = text.range(of: "</think>") {
            let after = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? nil : after
        }
        if let endRange = text.range(of: "</thinking>") {
            let after = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? nil : after
        }
        return nil
    }
    
    private func truncateToWidth(_ str: String, width: Int) -> String {
        guard width > 0 else { return "" }
        
        var result = ""
        var visibleCount = 0
        var inEscape = false
        
        for char in str {
            if char == "\u{1B}" {
                inEscape = true
                result.append(char)
            } else if inEscape {
                result.append(char)
                if char.isLetter { inEscape = false }
            } else {
                if visibleCount < width {
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
    
    private func visibleLength(_ str: String) -> Int {
        var count = 0
        var inEscape = false
        for char in str {
            if char == "\u{1B}" {
                inEscape = true
            } else if inEscape {
                if char.isLetter { inEscape = false }
            } else {
                count += 1
            }
        }
        return count
    }
}
