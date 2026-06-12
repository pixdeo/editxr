import Foundation

let arguments = CommandLine.arguments

if arguments.contains("--version") || arguments.contains("-v") {
    print("\(AppInfo.name) \(AppInfo.version)")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(AppInfo.helpText)
    exit(0)
}

// Every non-flag argument is a file to open; the first one is focused.
let filePaths = arguments.dropFirst().filter { !$0.hasPrefix("-") }
guard !filePaths.isEmpty else {
    print(AppInfo.helpText)
    exit(1)
}

let states = filePaths.map { EditorState(filePath: $0) }
let app = EditorApp(states: states)
app.start()
