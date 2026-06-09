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

// First non-flag argument is the file to open.
guard let filePath = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    print(AppInfo.helpText)
    exit(1)
}

let state = EditorState(filePath: filePath)
let app = EditorApp(state: state)
app.start()
