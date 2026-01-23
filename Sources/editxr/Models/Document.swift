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
}
