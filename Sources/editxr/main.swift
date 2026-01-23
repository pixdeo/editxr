import Foundation

let filePath: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

guard let filePath = filePath else {
    print("Usage: editxr <filename>")
    exit(1)
}

let state = EditorState(filePath: filePath)
let app = EditorApp(state: state)
app.start()
