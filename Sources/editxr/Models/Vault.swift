import Foundation

/// Which embedding backend vault search should use. Persisted as a raw string
/// so an unknown value from a newer build just falls back to `.auto`.
enum EmbedBackend: String, CaseIterable {
    case auto
    case apple
    case lmStudio = "lmstudio"
    case localModel = "local"
    case off

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .apple: return "Built into macOS"
        case .lmStudio: return "LM Studio"
        case .localModel: return "Local model"
        case .off: return "Off — text search only"
        }
    }
}

/// App-global vault state: which folder is the vault, the recents list, and the
/// search / index preferences.
///
/// Deliberately separate from EditorState, which is per-tab — the vault is one
/// per app. Persisted through Config with the same load-modify-save pattern, so
/// it never clobbers the fields EditorState owns.
final class Vault {
    /// Marker folders that identify a vault root when walking up from a file.
    static let markers = [".editxr", ".obsidian"]

    /// How many recent vaults to remember.
    static let maxRecents = 8

    /// Set from `--vault <path>` before the app starts; wins over the config.
    static var commandLineRoot: String?

    private(set) var configuredRoot: String?
    private(set) var recents: [String]
    private(set) var semanticSearch: Bool
    private(set) var backend: EmbedBackend
    private(set) var includeText: Bool
    private(set) var indexOnOpen: Bool
    private(set) var maxResults: Int

    init() {
        let config = Config.load()
        self.configuredRoot = Vault.commandLineRoot ?? config.vaultPath
        self.recents = config.recentVaults ?? []
        self.semanticSearch = config.vaultSemanticSearch ?? true
        self.backend = config.vaultEmbedBackend.flatMap(EmbedBackend.init(rawValue:)) ?? .auto
        self.includeText = config.vaultIncludeTxt ?? true
        self.indexOnOpen = config.vaultIndexOnOpen ?? true
        self.maxResults = Vault.clampResults(config.vaultMaxResults ?? 10)
    }

    // MARK: - Root resolution

    /// The vault root, in precedence order: an explicitly configured folder
    /// (`--vault` or the palette), then the nearest ancestor of `fileHint`
    /// holding a marker folder, then the folder the file itself lives in.
    ///
    /// The last step is what editxr did before vaults existed, so opening a file
    /// with nothing configured behaves exactly as it always has.
    func root(fileHint: String) -> String {
        Vault.resolveRoot(configured: configuredRoot, fileHint: fileHint)
    }

    /// The precedence rule on its own, so it can be exercised without loading or
    /// writing the user's config.
    static func resolveRoot(configured: String?, fileHint: String) -> String {
        if let configured, !configured.isEmpty {
            return standardized(configured)
        }
        let dir = containingDirectory(of: fileHint)
        return markerRoot(startingAt: dir) ?? dir
    }

    /// Whether the root comes from a real setting rather than the open file.
    var isExplicit: Bool { !(configuredRoot ?? "").isEmpty }

    /// Walk up from `dir` looking for a marker folder. Pure filesystem probing,
    /// no side effects; returns nil when nothing is found before the volume root.
    static func markerRoot(startingAt dir: String) -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            for marker in markers {
                var isDir: ObjCBool = false
                let candidate = current.appendingPathComponent(marker).path
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                    return current.path
                }
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    static func containingDirectory(of path: String) -> String {
        let dir = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        return dir.isEmpty ? FileManager.default.currentDirectoryPath : dir
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// `~`-shortened form for menu labels, so a long home path stays readable.
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }

    // MARK: - Recents

    /// Most-recent-first, de-duplicated by standardized path, capped. Pure so the
    /// ordering rules are unit-testable without touching disk.
    static func recents(adding path: String, to existing: [String], limit: Int = maxRecents) -> [String] {
        let entry = standardized(path)
        var list = existing.filter { standardized($0) != entry }
        list.insert(entry, at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        return list
    }

    static func clampResults(_ n: Int) -> Int { max(1, min(50, n)) }

    // MARK: - Mutations

    func setRoot(_ path: String?) {
        if let path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            let resolved = Vault.standardized(path)
            configuredRoot = resolved
            recents = Vault.recents(adding: resolved, to: recents)
        } else {
            configuredRoot = nil
        }
        save()
    }

    func setSemanticSearch(_ on: Bool) { semanticSearch = on; save() }
    func setBackend(_ b: EmbedBackend) { backend = b; save() }
    func setIncludeText(_ on: Bool) { includeText = on; save() }
    func setIndexOnOpen(_ on: Bool) { indexOnOpen = on; save() }
    func setMaxResults(_ n: Int) { maxResults = Vault.clampResults(n); save() }

    /// Load-modify-save so the fields EditorState owns survive untouched.
    private func save() {
        var config = Config.load()
        config.vaultPath = configuredRoot
        config.recentVaults = recents.isEmpty ? nil : recents
        config.vaultSemanticSearch = semanticSearch
        config.vaultEmbedBackend = backend.rawValue
        config.vaultIncludeTxt = includeText
        config.vaultIndexOnOpen = indexOnOpen
        config.vaultMaxResults = maxResults
        config.save()
    }
}
