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
    @Published var wordWrap: Bool = true
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
    
    func toggleWordWrap() {
        wordWrap.toggle()
        scrollX = 0
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
    
    private var lastViewportWidth: Int = 80
    
    func moveUp(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        
        if wordWrap {
            moveUpWrapped()
        } else {
            document.moveUp()
        }
    }
    
    func moveDown(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        
        if wordWrap {
            moveDownWrapped()
        } else {
            document.moveDown()
        }
    }
    
    private func moveUpWrapped() {
        let line = document.currentLineText
        let segments = wrapLineForNavigation(line, width: lastViewportWidth)
        
        var currentSegmentIndex = 0
        var localColumn = document.cursorColumn
        
        for (i, seg) in segments.enumerated() {
            if document.cursorColumn >= seg.startOffset && document.cursorColumn < seg.startOffset + seg.segment.count + 1 {
                currentSegmentIndex = i
                localColumn = document.cursorColumn - seg.startOffset
                break
            }
        }
        
        if currentSegmentIndex > 0 {
            let prevSegment = segments[currentSegmentIndex - 1]
            document.cursorColumn = min(prevSegment.startOffset + localColumn, prevSegment.startOffset + prevSegment.segment.count)
        } else {
            if document.cursorLine > 0 {
                document.cursorLine -= 1
                let prevLine = document.currentLineText
                let prevSegments = wrapLineForNavigation(prevLine, width: lastViewportWidth)
                if let lastSeg = prevSegments.last {
                    document.cursorColumn = min(lastSeg.startOffset + localColumn, prevLine.count)
                }
            }
        }
    }
    
    private func moveDownWrapped() {
        let line = document.currentLineText
        let segments = wrapLineForNavigation(line, width: lastViewportWidth)
        
        var currentSegmentIndex = 0
        var localColumn = document.cursorColumn
        
        for (i, seg) in segments.enumerated() {
            let segEnd = i == segments.count - 1 ? seg.startOffset + seg.segment.count + 1 : seg.startOffset + seg.segment.count
            if document.cursorColumn >= seg.startOffset && document.cursorColumn < segEnd {
                currentSegmentIndex = i
                localColumn = document.cursorColumn - seg.startOffset
                break
            }
        }
        
        if currentSegmentIndex < segments.count - 1 {
            let nextSegment = segments[currentSegmentIndex + 1]
            document.cursorColumn = min(nextSegment.startOffset + localColumn, nextSegment.startOffset + nextSegment.segment.count)
        } else {
            if document.cursorLine < document.lines.count - 1 {
                document.cursorLine += 1
                let nextLine = document.currentLineText
                let nextSegments = wrapLineForNavigation(nextLine, width: lastViewportWidth)
                if let firstSeg = nextSegments.first {
                    document.cursorColumn = min(firstSeg.startOffset + localColumn, nextLine.count)
                }
            }
        }
    }
    
    private func wrapLineForNavigation(_ line: String, width: Int) -> [(segment: String, startOffset: Int)] {
        guard width > 0 else { return [(line, 0)] }
        if line.isEmpty { return [("", 0)] }
        if line.count <= width { return [(line, 0)] }
        
        var segments: [(segment: String, startOffset: Int)] = []
        var remaining = line
        var offset = 0
        
        while !remaining.isEmpty {
            if remaining.count <= width {
                segments.append((remaining, offset))
                break
            }
            
            let chunk = String(remaining.prefix(width))
            if let lastSpace = chunk.lastIndex(of: " "), lastSpace > chunk.startIndex {
                let breakPoint = chunk.distance(from: chunk.startIndex, to: lastSpace)
                segments.append((String(remaining.prefix(breakPoint)), offset))
                offset += breakPoint + 1
                remaining = String(remaining.dropFirst(breakPoint + 1))
            } else {
                segments.append((chunk, offset))
                offset += width
                remaining = String(remaining.dropFirst(width))
            }
        }
        
        return segments.isEmpty ? [("", 0)] : segments
    }
    
    func setViewportWidth(_ width: Int) {
        lastViewportWidth = width
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
        if wordWrap {
            adjustScrollWrapped(viewportHeight: viewportHeight, viewportWidth: viewportWidth)
            return
        }
        
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
    
    private func adjustScrollWrapped(viewportHeight: Int, viewportWidth: Int) {
        let cursorVisualLine = visualLineForCursor(viewportWidth: viewportWidth)
        
        if cursorVisualLine < scrollOffset + scrollMargin {
            scrollOffset = max(0, cursorVisualLine - scrollMargin)
        }
        
        let bottomEdge = scrollOffset + viewportHeight - 1
        if cursorVisualLine > bottomEdge - scrollMargin {
            scrollOffset = cursorVisualLine - viewportHeight + scrollMargin + 1
        }
        
        let totalVisualLines = countVisualLines(viewportWidth: viewportWidth)
        let maxScroll = max(0, totalVisualLines - viewportHeight)
        scrollOffset = min(scrollOffset, maxScroll)
    }
    
    private func visualLineForCursor(viewportWidth: Int) -> Int {
        var visualLine = 0
        for i in 0..<document.cursorLine {
            visualLine += wrappedLineCount(document.lines[i], width: viewportWidth)
        }
        let currentLine = document.lines[document.cursorLine]
        let segmentIndex = document.cursorColumn / max(1, viewportWidth)
        visualLine += min(segmentIndex, wrappedLineCount(currentLine, width: viewportWidth) - 1)
        return visualLine
    }
    
    private func countVisualLines(viewportWidth: Int) -> Int {
        var total = 0
        for line in document.lines {
            total += wrappedLineCount(line, width: viewportWidth)
        }
        return total
    }
    
    private func wrappedLineCount(_ line: String, width: Int) -> Int {
        guard width > 0 else { return 1 }
        if line.isEmpty { return 1 }
        if line.count <= width { return 1 }
        
        var count = 0
        var remaining = line.count
        
        while remaining > 0 {
            count += 1
            remaining -= width
        }
        
        return max(1, count)
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
