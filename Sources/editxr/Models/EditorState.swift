import Foundation

enum ViewMode {
    case plain
    case rendered
}

class EditorState: ObservableObject {
    let filePath: String
    @Published var document: Document
    @Published var viewMode: ViewMode = .plain
    @Published var showStatusBar: Bool = true
    @Published var showHelp: Bool = true
    @Published var isDirty: Bool = false
    @Published var showSavedIndicator: Bool = false
    
    private var clipboard: String = ""
    private var savedTimer: DispatchWorkItem?
    
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
        viewMode = viewMode == .plain ? .rendered : .plain
    }
    
    func toggleStatusBar() {
        showStatusBar.toggle()
    }
    
    func toggleHelp() {
        showHelp.toggle()
    }
    
    func handleCharacter(_ char: Character) {
        if document.hasSelection {
            document.deleteSelection()
        }
        document.insertCharacter(char)
        isDirty = true
    }
    
    func handleNewline() {
        if document.hasSelection {
            document.deleteSelection()
        }
        document.insertNewline()
        isDirty = true
    }
    
    func handleBackspace() {
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
            clipboard = text
            document.deleteSelection()
            isDirty = true
        }
    }
    
    func paste() {
        guard !clipboard.isEmpty else { return }
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
        document.moveLeft()
    }
    
    func moveRight(selecting: Bool = false) {
        if selecting { document.startSelection() } else { document.clearSelection() }
        document.moveRight()
    }
}
