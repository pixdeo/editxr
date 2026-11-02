import Foundation

/// Bridges copy/cut/paste to the OS clipboard via the platform's CLI tools, so
/// text moves between editxr and other apps. macOS uses `pbcopy`/`pbpaste`;
/// Linux tries Wayland (`wl-copy`/`wl-paste`) then X11 (`xclip`, `xsel`).
/// Every call fails silently when no tool is present — the editor keeps its own
/// in-memory buffer as a backstop.
enum SystemClipboard {

    private struct Tool { let name: String; let args: [String] }

    private static let writeTools: [Tool] = [
        Tool(name: "pbcopy", args: []),
        Tool(name: "wl-copy", args: []),
        Tool(name: "xclip", args: ["-selection", "clipboard"]),
        Tool(name: "xsel", args: ["--clipboard", "--input"]),
    ]

    private static let readTools: [Tool] = [
        Tool(name: "pbpaste", args: []),
        Tool(name: "wl-paste", args: ["--no-newline"]),
        Tool(name: "xclip", args: ["-selection", "clipboard", "-o"]),
        Tool(name: "xsel", args: ["--clipboard", "--output"]),
    ]

    /// Writes run in order, off the main thread: the UI never waits on a helper.
    private static let writes = DispatchQueue(label: "editxr.clipboard.write")

    /// How long a helper gets to report failure. `wl-copy`, `xclip` and `xsel`
    /// stay behind to own the selection, and on Linux a Foundation `Process` keeps
    /// reporting running for as long as that daemon holds its inherited sockets —
    /// waiting for it to exit never returns. A helper that fails does so at once,
    /// so one that is still running after this has taken the text.
    static let helperGrace: TimeInterval = 0.3

    /// Write `text` to the system clipboard, in the background.
    static func write(_ text: String) {
        let helpers = writeTools.compactMap { tool in
            resolve(tool.name).map { (path: $0, args: tool.args) }
        }
        write(text, using: helpers)
    }

    /// Offer `text` to each helper in turn until one takes it.
    static func write(_ text: String, using helpers: [(path: String, args: [String])],
                      grace: TimeInterval = helperGrace) {
        writes.async {
            for helper in helpers where run(helper.path, args: helper.args, input: text, grace: grace) { return }
        }
    }

    /// Block until every write so far has been handed to a helper.
    static func waitForPendingWrites() {
        writes.sync {}
    }

    /// Read the system clipboard, or nil if unavailable/empty.
    static func read() -> String? {
        waitForPendingWrites()
        for tool in readTools {
            guard let path = resolve(tool.name) else { continue }
            if let out = capture(path, args: tool.args) { return out }
        }
        return nil
    }

    // MARK: - Helpers

    /// Resolve a tool name to an absolute path on $PATH, so we only ever launch
    /// processes that exist (avoids SIGPIPE from writing to a failed `env`).
    private static func resolve(_ tool: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let full = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    /// A helper that exits before reading its input turns the write into SIGPIPE,
    /// which ends the process unless it is ignored.
    private static let brokenPipesIgnored: Void = {
        #if !os(Windows)
        signal(SIGPIPE, SIG_IGN)
        #endif
    }()

    private static func run(_ path: String, args: [String], input: String, grace: TimeInterval) -> Bool {
        _ = brokenPipesIgnored
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }

        // Input past the pipe's capacity blocks until the helper reads it, so it
        // gets its own thread: a helper that never reads can't hold up the rest.
        let handle = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? handle.write(contentsOf: Data(input.utf8))   // failure shows in the exit status
            try? handle.close()
        }

        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < deadline { usleep(5_000) }
        return p.isRunning || p.terminationStatus == 0
    }

    private static func capture(_ path: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let stdout = Pipe()
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), !s.isEmpty else {
            return nil
        }
        return s
    }
}
