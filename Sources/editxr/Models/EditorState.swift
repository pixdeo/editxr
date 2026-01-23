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
    @Published var isDirty: Bool = false
    
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
        } catch { }
    }
    
    func toggleViewMode() {
        viewMode = viewMode == .plain ? .rendered : .plain
    }
    
    func toggleStatusBar() {
        showStatusBar.toggle()
    }
    
    func handleCharacter(_ char: Character) {
        document.insertCharacter(char)
        isDirty = true
    }
    
    func handleNewline() {
        document.insertNewline()
        isDirty = true
    }
    
    func handleBackspace() {
        document.deleteBackward()
        isDirty = true
    }
    
    func moveUp() { document.moveUp() }
    func moveDown() { document.moveDown() }
    func moveLeft() { document.moveLeft() }
    func moveRight() { document.moveRight() }
}
