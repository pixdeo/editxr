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
    /// Called with the final generated text on success. The modal hands off to
    /// the inline-diff review flow instead of applying directly.
    var onResultReady: ((String) -> Void)?

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
    
    private func accentBar() -> String {
        "\(Theme.accent)▌\(Theme.statusBarBg)\(Theme.statusBarText)"
    }
    
    func render(width: Int) -> [String] {
        guard isVisible else { return [] }
        
        let bar = accentBar()
        let contentWidth = width - 1
        let maxContentLines = 6
        
        var lines: [String] = []
        
        switch state {
        case .inputting:
            let cursor = "\(Theme.inverse) \(Theme.reset)\(Theme.statusBarBg)\(Theme.statusBarText)"
            let text = inputBuffer + cursor
            let textLen = inputBuffer.count + 1
            let padding = max(0, contentWidth - textLen)
            lines.append("\(bar)\(text)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .processing:
            let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            let idx = Int(Date().timeIntervalSince1970 * 10) % spinner.count
            let text = "\(spinner[idx]) Processing..."
            let padding = max(0, contentWidth - text.count)
            lines.append("\(bar)\(text)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .streaming:
            let contentLines = wrapContent(streamedContent, width: contentWidth)
            let displayLines = contentLines.suffix(maxContentLines)
            for line in displayLines {
                let padding = max(0, contentWidth - line.count)
                lines.append("\(bar)\(line)\(String(repeating: " ", count: padding))\(Theme.reset)")
            }
            if lines.isEmpty {
                let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
                let idx = Int(Date().timeIntervalSince1970 * 10) % spinner.count
                let text = "\(spinner[idx]) Thinking..."
                let padding = max(0, contentWidth - text.count)
                lines.append("\(bar)\(text)\(String(repeating: " ", count: padding))\(Theme.reset)")
            }
            
        case .result(let text):
            let contentLines = wrapContent(text, width: contentWidth)
            let displayLines = contentLines.suffix(maxContentLines)
            for line in displayLines {
                let padding = max(0, contentWidth - line.count)
                lines.append("\(bar)\(line)\(String(repeating: " ", count: padding))\(Theme.reset)")
            }
            
        case .error(let message):
            let text = "⚠ \(message)"
            let displayText = truncateToWidth(text, width: contentWidth)
            let visLen = visibleLength(displayText)
            let padding = max(0, contentWidth - visLen)
            lines.append("\(bar)\(displayText)\(String(repeating: " ", count: padding))\(Theme.reset)")
            
        case .hidden:
            return []
        }
        
        lines.append(renderHintsLine(width: width))
        
        return lines
    }
    
    private func wrapContent(_ content: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var result: [String] = []
        
        for line in content.components(separatedBy: "\n") {
            if line.isEmpty {
                result.append("")
                continue
            }
            var remaining = line
            while !remaining.isEmpty {
                if remaining.count <= width {
                    result.append(remaining)
                    break
                }
                let chunk = String(remaining.prefix(width))
                if let lastSpace = chunk.lastIndex(of: " "), lastSpace > chunk.startIndex {
                    let breakPoint = chunk.distance(from: chunk.startIndex, to: lastSpace)
                    result.append(String(remaining.prefix(breakPoint)))
                    remaining = String(remaining.dropFirst(breakPoint + 1))
                } else {
                    result.append(chunk)
                    remaining = String(remaining.dropFirst(width))
                }
            }
        }
        
        return result
    }
    
    private func renderHintsLine(width: Int) -> String {
        let bar = accentBar()
        let contentWidth = width - 1
        let hints: String
        switch state {
        case .inputting:
            hints = "Enter send  Esc cancel"
        case .processing, .streaming:
            hints = "Esc cancel"
        case .result:
            hints = "Tab accept  Esc cancel"
        case .error:
            hints = "Esc dismiss"
        case .hidden:
            hints = ""
        }
        
        let hintsLen = hints.count
        let padding = max(0, contentWidth - hintsLen)
        return "\(bar)\(hints)\(String(repeating: " ", count: padding))\(Theme.reset)"
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
                    self.hide()
                    self.onResultReady?(finalResult)
                    return
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
