import Foundation

/// Remembers the last cursor position per file so reopening a document
/// restores where you left off.
///
/// Stored centrally in the config dir (keyed by absolute path) rather than as
/// sidecar files, so it never clutters the directories you edit in.
enum CursorStore {
    struct Position: Codable {
        var line: Int
        var column: Int
        var scroll: Int
    }

    private static let storePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/editxr/positions.json"
    }()

    /// Cap the store so it can't grow without bound across many files.
    private static let maxEntries = 500

    private static func key(for path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func readAll() -> [String: Position] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storePath)),
              let all = try? JSONDecoder().decode([String: Position].self, from: data) else {
            return [:]
        }
        return all
    }

    static func load(for path: String) -> Position? {
        readAll()[key(for: path)]
    }

    static func save(_ position: Position, for path: String) {
        var all = readAll()
        all[key(for: path)] = position
        if all.count > maxEntries {
            // No recency tracking; just keep the file bounded.
            for k in all.keys.shuffled().prefix(all.count - maxEntries) { all[k] = nil }
        }

        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: URL(fileURLWithPath: storePath))
        }
    }
}
