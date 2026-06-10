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

    /// Write `text` to the system clipboard. Returns true if a tool accepted it.
    @discardableResult
    static func write(_ text: String) -> Bool {
        for tool in writeTools {
            guard let path = resolve(tool.name) else { continue }
            if run(path, args: tool.args, input: text) { return true }
        }
        return false
    }

    /// Read the system clipboard, or nil if unavailable/empty.
    static func read() -> String? {
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

    private static func run(_ path: String, args: [String], input: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        p.waitUntilExit()
        return p.terminationStatus == 0
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
