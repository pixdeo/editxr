import Foundation

struct Document {
    var lines: [String]
    var cursorLine: Int
    var cursorColumn: Int
    
    init(content: String = "") {
        self.lines = content.isEmpty ? [""] : content.components(separatedBy: "\n")
        self.cursorLine = 0
        self.cursorColumn = 0
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
