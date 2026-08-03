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
    // Refresh the on-disk cache from this fresh run, so the flag doubles as
    // "re-calibrate" after changing a terminal setting that alters emoji width.
    var fresh: [Character: Int] = [:]
    for (s, w) in measured { if let c = s.first { fresh[c] = w } }
    registerMeasuredWidths(fresh)
    GlyphWidthCache.save()
    print("cache: \(GlyphWidthCache.path)")
    exit(0)
}

// --vault <path> pins the vault root for this run, overriding the config. Its
// value is a bare path, so it has to be pulled out before the file list is read.
var vaultArgIndex: Int?
if let i = arguments.firstIndex(of: "--vault"), i + 1 < arguments.count {
    Vault.commandLineRoot = Vault.standardized(arguments[i + 1])
    vaultArgIndex = i + 1
}

// Every non-flag argument is a file to open; the first one is focused.
let filePaths = arguments.enumerated()
    .filter { $0.offset > 0 && $0.offset != vaultArgIndex && !$0.element.hasPrefix("-") }
    .map(\.element)
guard !filePaths.isEmpty else {
    print(AppInfo.helpText)
    exit(1)
}

let states = filePaths.map { EditorState(filePath: $0) }
let app = EditorApp(states: states)
app.start()
