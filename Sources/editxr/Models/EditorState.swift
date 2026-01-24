import Foundation

enum ViewMode {
    case normal
    case raw
}

struct DocumentSnapshot {
    let lines: [String]
    let cursorLine: Int
    let cursorColumn: Int
}

class EditorState: ObservableObject {
    let filePath: String
    @Published var document: Document
    @Published var viewMode: ViewMode = .normal
    @Published var showStatusBar: Bool = true
    @Published var showHelp: Bool = true
    @Published var showLineNumbers: Bool = false
    @Published var isDirty: Bool = false
    @Published var showSavedIndicator: Bool = false
    @Published var scrollOffset: Int = 0
    @Published var scrollX: Int = 0
    
    private var clipboard: String = ""
    private var savedTimer: DispatchWorkItem?
    
    private var undoStack: [DocumentSnapshot] = []
    private var redoStack: [DocumentSnapshot] = []
    private let maxUndoLevels = 100
    private let scrollMargin = 4
    private let scrollMarginX = 8
    
    var onSavedIndicatorChanged: (() -> Void)?
    
    init(filePath: String) {
        self.filePath = filePath
        self.document = Document()
        loadFile()
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
    }
    
    func toggleStatusBar() {
        showStatusBar.toggle()
    }
    
    func toggleLineNumbers() {
        showLineNumbers.toggle()
    }
    
    func toggleHelp() {
        showHelp.toggle()
    }
    
    func handleCharacter(_ char: Character) {
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
        }
        document.insertCharacter(char)
        isDirty = true
    }
    
    func handleNewline() {
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
        }
        document.insertNewline()
        isDirty = true
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
    
    func deleteSelection() {
        if document.hasSelection {
            saveSnapshot()
            document.deleteSelection()
            isDirty = true
        }
    }
    
    func copy() {
        if let text = document.selectedText {
            clipboard = text
        }
    }
    
    func cut() {
        if let text = document.selectedText {
            saveSnapshot()
            clipboard = text
            document.deleteSelection()
            isDirty = true
        }
    }
    
    func paste() {
        guard !clipboard.isEmpty else { return }
        saveSnapshot()
        if document.hasSelection {
            document.deleteSelection()
        }
        for char in clipboard {
            if char == "\n" {
                document.insertNewline()
            } else {
                document.insertCharacter(char)
            }
        }
        isDirty = true
    }
    
    func moveUp(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        document.moveUp()
    }
    
    func moveDown(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        document.moveDown()
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
    
    func adjustScroll(viewportHeight: Int, viewportWidth: Int) {
        let cursorLine = document.cursorLine
        let cursorColumn = document.cursorColumn
        
        if cursorLine < scrollOffset + scrollMargin {
            scrollOffset = max(0, cursorLine - scrollMargin)
        }
        
        let bottomEdge = scrollOffset + viewportHeight - 1
        if cursorLine > bottomEdge - scrollMargin {
            scrollOffset = cursorLine - viewportHeight + scrollMargin + 1
        }
        
        let maxScroll = max(0, document.lines.count - viewportHeight)
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
    
    func pageUp(viewportHeight: Int) {
        let pageSize = viewportHeight - scrollMargin
        document.cursorLine = max(0, document.cursorLine - pageSize)
        document.cursorColumn = min(document.cursorColumn, document.currentLineText.count)
        document.clearSelection()
        scrollOffset = max(0, scrollOffset - pageSize)
    }
    
    func pageDown(viewportHeight: Int) {
        let pageSize = viewportHeight - scrollMargin
        document.cursorLine = min(document.lines.count - 1, document.cursorLine + pageSize)
        document.cursorColumn = min(document.cursorColumn, document.currentLineText.count)
        document.clearSelection()
        scrollOffset = min(max(0, document.lines.count - viewportHeight), scrollOffset + pageSize)
    }
}
