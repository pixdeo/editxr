import Foundation

struct Config: Codable {
    var wordWrap: Bool = true
    var renderMarkdown: Bool = true
    // Optional so configs written before this field still decode.
    var showLineNumbers: Bool? = false
    var statusBarBig: Bool? = true
    var scrollPastEnd: Bool? = true
    var fullTable: Bool? = true
    var alignTables: Bool? = true       // render every table as wide as the widest
    var contextHelp: Bool? = true
    var blockMode: Bool? = true
    var showOutline: Bool? = false      // legacy; migrated to `sidebar` on load
    var sidebar: String? = nil          // SidebarMode raw value (off/outline/files)
    var leftMargin: Int? = 1
    var scrollOff: Int? = 4
    // Stored as the raw string so renaming/removing a theme can't make the
    // whole config fail to decode; unknown values just fall back to default.
    var theme: String? = nil
    var appearance: String? = nil

    // Vault. All optional with defaults, so a config written before vaults
    // existed still decodes and keeps today's implicit behaviour.
    var vaultPath: String? = nil            // nil = follow the open file's folder
    var recentVaults: [String]? = nil       // most-recent-first, capped
    var vaultSemanticSearch: Bool? = true
    var vaultEmbedBackend: String? = nil    // EmbedBackend raw value
    var vaultIncludeTxt: Bool? = true
    var vaultIndexOnOpen: Bool? = true
    var vaultMaxResults: Int? = 10

    var llmProvider: LLMProvider = .lmStudio
    var openRouterKey: String? = nil
    var openRouterModel: String? = nil
    var openAIAccessToken: String? = nil
    var openAIRefreshToken: String? = nil
    var openAIExpiresAt: Double? = nil
    
    static let configPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/editxr/config.json"
    }()
    
    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configPath) else {
            return Config()
        }
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            return Config()
        }
    }
    
    func save() {
        let dir = (Config.configPath as NSString).deletingLastPathComponent
        
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            // Readable on disk so the file is comfortable to hand-edit.
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            try data.write(to: URL(fileURLWithPath: Config.configPath))
        } catch { }
    }
}
