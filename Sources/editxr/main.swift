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

// Diagnostic: ask the live terminal how wide each symbol renders and compare it
// to the built-in heuristic. Handy when a table looks misaligned on a terminal.
if arguments.contains("--probe-widths") {
    let symbols = ["★", "☆", "✓", "✔", "➡", "♻", "☀", "⚠", "⚠️", "✅", "⛔",
                   "⏰", "☑", "☐", "▶️", "❤️", "🎭", "你", "→", "—", "…"]
    PlatformTerminal.enableRawMode()
    let measured = PlatformTerminal.probeWidths(symbols)
    PlatformTerminal.disableRawMode()
    print("\u{1B}[H\u{1B}[2J", terminator: "")   // undo the probe's scratch draw
    print("symbol  measured  heuristic")
    for s in symbols {
        let m = measured[s].map(String.init) ?? "—"
        let h = s.first.map { displayWidth($0) } ?? 0
        print("  \(s)       \(m)         \(h)")
    }
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
