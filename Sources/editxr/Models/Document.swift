import Foundation

struct CursorPosition: Equatable {
    var line: Int
    var column: Int
}

struct Document {
    var lines: [String]
    var cursorLine: Int
    var cursorColumn: Int
    var selectionAnchor: CursorPosition?
    
    init(content: String = "") {
        self.lines = content.isEmpty ? [""] : content.components(separatedBy: "\n")
        self.cursorLine = 0
        self.cursorColumn = 0
        self.selectionAnchor = nil
        ensureTrailingEmptyLine()
    }
    
    private mutating func ensureTrailingEmptyLine() {
        if lines.isEmpty || !lines.last!.isEmpty {
            lines.append("")
        }
    }
    
    var cursorPosition: CursorPosition {
        CursorPosition(line: cursorLine, column: cursorColumn)
    }
    
    var hasSelection: Bool {
        guard let anchor = selectionAnchor else { return false }
        return anchor != cursorPosition
    }
    
    var selectionRange: (start: CursorPosition, end: CursorPosition)? {
        guard let anchor = selectionAnchor, hasSelection else { return nil }
        let cursor = cursorPosition
        if anchor.line < cursor.line || (anchor.line == cursor.line && anchor.column < cursor.column) {
            return (anchor, cursor)
        }
        return (cursor, anchor)
    }
    
    var selectedText: String? {
        guard let range = selectionRange else { return nil }
        
        if range.start.line == range.end.line {
            let line = lines[range.start.line]
            let startIdx = line.index(line.startIndex, offsetBy: range.start.column)
            let endIdx = line.index(line.startIndex, offsetBy: range.end.column)
            return String(line[startIdx..<endIdx])
        }
        
        var result: [String] = []
        
        let firstLine = lines[range.start.line]
        let firstIdx = firstLine.index(firstLine.startIndex, offsetBy: range.start.column)
        result.append(String(firstLine[firstIdx...]))
        
        for i in (range.start.line + 1)..<range.end.line {
            result.append(lines[i])
        }
        
        let lastLine = lines[range.end.line]
        let lastIdx = lastLine.index(lastLine.startIndex, offsetBy: range.end.column)
        result.append(String(lastLine[..<lastIdx]))
        
        return result.joined(separator: "\n")
    }
    
    mutating func startSelection() {
        if selectionAnchor == nil {
            selectionAnchor = cursorPosition
        }
    }
    
    mutating func clearSelection() {
        selectionAnchor = nil
    }
    
    mutating func replaceRange(_ range: (start: CursorPosition, end: CursorPosition), with text: String) {
        if range.start.line == range.end.line {
            var line = lines[range.start.line]
            let startIdx = line.index(line.startIndex, offsetBy: min(range.start.column, line.count))
            let endIdx = line.index(line.startIndex, offsetBy: min(range.end.column, line.count))
            line.replaceSubrange(startIdx..<endIdx, with: text)
            lines[range.start.line] = line
        } else {
            let firstLine = lines[range.start.line]
            let lastLine = lines[range.end.line]
            let startIdx = firstLine.index(firstLine.startIndex, offsetBy: min(range.start.column, firstLine.count))
            let endIdx = lastLine.index(lastLine.startIndex, offsetBy: min(range.end.column, lastLine.count))
            
            let newContent = String(firstLine[..<startIdx]) + text + String(lastLine[endIdx...])
            let newLines = newContent.components(separatedBy: "\n")
            
            lines.replaceSubrange(range.start.line...range.end.line, with: newLines)
        }
        
        let newLines = text.components(separatedBy: "\n")
        if newLines.count == 1 {
            cursorLine = range.start.line
            cursorColumn = range.start.column + text.count
        } else {
            cursorLine = range.start.line + newLines.count - 1
            cursorColumn = newLines.last?.count ?? 0
        }
        clearSelection()
    }
    
    mutating func deleteSelection() {
        guard let range = selectionRange else { return }
        
        if range.start.line == range.end.line {
            var line = lines[range.start.line]
            let startIdx = line.index(line.startIndex, offsetBy: range.start.column)
            let endIdx = line.index(line.startIndex, offsetBy: range.end.column)
            line.removeSubrange(startIdx..<endIdx)
            lines[range.start.line] = line
        } else {
            let firstLine = lines[range.start.line]
            let lastLine = lines[range.end.line]
            let startIdx = firstLine.index(firstLine.startIndex, offsetBy: range.start.column)
            let endIdx = lastLine.index(lastLine.startIndex, offsetBy: range.end.column)
            
            let newLine = String(firstLine[..<startIdx]) + String(lastLine[endIdx...])
            lines[range.start.line] = newLine
            lines.removeSubrange((range.start.line + 1)...(range.end.line))
        }
        
        cursorLine = range.start.line
        cursorColumn = range.start.column
        clearSelection()
    }
    
    var content: String {
        lines.joined(separator: "\n")
    }
    
    var wordCount: Int {
        let text = content
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        return words.filter { !$0.isEmpty }.count
    }
    
    var currentLineText: String {
        guard cursorLine < lines.count else { return "" }
        return lines[cursorLine]
    }
    
    var currentParagraph: String {
        guard cursorLine < lines.count else { return "" }
        
        var startLine = cursorLine
        while startLine > 0 && !lines[startLine - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            startLine -= 1
        }
        
        var endLine = cursorLine
        while endLine < lines.count - 1 && !lines[endLine].trimmingCharacters(in: .whitespaces).isEmpty {
            endLine += 1
        }
        
        if lines[endLine].trimmingCharacters(in: .whitespaces).isEmpty && endLine > startLine {
            endLine -= 1
        }
        
        return lines[startLine...endLine].joined(separator: "\n")
    }
    
    var currentParagraphRange: (start: CursorPosition, end: CursorPosition)? {
        guard cursorLine < lines.count else { return nil }
        
        var startLine = cursorLine
        while startLine > 0 && !lines[startLine - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            startLine -= 1
        }
        
        var endLine = cursorLine
        while endLine < lines.count - 1 && !lines[endLine].trimmingCharacters(in: .whitespaces).isEmpty {
            endLine += 1
        }
        
        if lines[endLine].trimmingCharacters(in: .whitespaces).isEmpty && endLine > startLine {
            endLine -= 1
        }
        
        let endColumn = lines[endLine].count
        return (CursorPosition(line: startLine, column: 0), CursorPosition(line: endLine, column: endColumn))
    }
    
    func textInRange(_ range: (start: CursorPosition, end: CursorPosition)) -> String {
        if range.start.line == range.end.line {
            let line = lines[range.start.line]
            let startIdx = line.index(line.startIndex, offsetBy: min(range.start.column, line.count))
            let endIdx = line.index(line.startIndex, offsetBy: min(range.end.column, line.count))
            return String(line[startIdx..<endIdx])
        }
        
        var result: [String] = []
        
        let firstLine = lines[range.start.line]
        let firstIdx = firstLine.index(firstLine.startIndex, offsetBy: min(range.start.column, firstLine.count))
        result.append(String(firstLine[firstIdx...]))
        
        for i in (range.start.line + 1)..<range.end.line {
            result.append(lines[i])
        }
        
        let lastLine = lines[range.end.line]
        let lastIdx = lastLine.index(lastLine.startIndex, offsetBy: min(range.end.column, lastLine.count))
        result.append(String(lastLine[..<lastIdx]))
        
        return result.joined(separator: "\n")
    }
    
    mutating func insertCharacter(_ char: Character) {
        guard cursorLine < lines.count else { return }
        var line = lines[cursorLine]
        let index = line.index(line.startIndex, offsetBy: min(cursorColumn, line.count))
        line.insert(char, at: index)
        lines[cursorLine] = line
        cursorColumn += 1
    }
    
    mutating func insertNewline() {
        guard cursorLine < lines.count else { return }
        let line = lines[cursorLine]
        let index = line.index(line.startIndex, offsetBy: min(cursorColumn, line.count))
        let before = String(line[..<index])
        let after = String(line[index...])
        lines[cursorLine] = before
        lines.insert(after, at: cursorLine + 1)
        cursorLine += 1
        cursorColumn = 0
        ensureTrailingEmptyLine()
    }
    
    mutating func deleteBackward() {
        guard cursorLine < lines.count else { return }
        
        if cursorColumn > 0 {
            var line = lines[cursorLine]
            let index = line.index(line.startIndex, offsetBy: cursorColumn - 1)
            line.remove(at: index)
            lines[cursorLine] = line
            cursorColumn -= 1
        } else if cursorLine > 0 {
            let currentLine = lines.remove(at: cursorLine)
            cursorLine -= 1
            cursorColumn = lines[cursorLine].count
            lines[cursorLine] += currentLine
        }
        ensureTrailingEmptyLine()
    }
    
    mutating func moveUp() {
        if cursorLine > 0 {
            cursorLine -= 1
            cursorColumn = min(cursorColumn, lines[cursorLine].count)
        }
    }
    
    mutating func moveDown() {
        if cursorLine < lines.count - 1 {
            cursorLine += 1
            cursorColumn = min(cursorColumn, lines[cursorLine].count)
        }
    }
    
    mutating func moveLeft() {
        if cursorColumn > 0 {
            cursorColumn -= 1
        } else if cursorLine > 0 {
            cursorLine -= 1
            cursorColumn = lines[cursorLine].count
        }
    }
    
    mutating func moveRight() {
        let lineLength = cursorLine < lines.count ? lines[cursorLine].count : 0
        if cursorColumn < lineLength {
            cursorColumn += 1
        } else if cursorLine < lines.count - 1 {
            cursorLine += 1
            cursorColumn = 0
        }
    }
    
    mutating func moveWordLeft() {
        if cursorColumn == 0 && cursorLine > 0 {
            cursorLine -= 1
            cursorColumn = lines[cursorLine].count
            return
        }
        
        guard cursorLine < lines.count else { return }
        let line = lines[cursorLine]
        guard !line.isEmpty && cursorColumn > 0 else { return }
        
        let chars = Array(line)
        var pos = min(cursorColumn - 1, chars.count - 1)
        
        while pos > 0 && !chars[pos].isLetter && !chars[pos].isNumber {
            pos -= 1
        }
        
        while pos > 0 && (chars[pos - 1].isLetter || chars[pos - 1].isNumber) {
            pos -= 1
        }
        
        cursorColumn = pos
    }
    
    mutating func moveWordRight() {
        guard cursorLine < lines.count else { return }
        let line = lines[cursorLine]
        
        if cursorColumn >= line.count {
            if cursorLine < lines.count - 1 {
                cursorLine += 1
                cursorColumn = 0
            }
            return
        }
        
        let chars = Array(line)
        var pos = cursorColumn
        
        while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber) {
            pos += 1
        }
        
        while pos < chars.count && !chars[pos].isLetter && !chars[pos].isNumber {
            pos += 1
        }
        
        cursorColumn = pos
    }
}
