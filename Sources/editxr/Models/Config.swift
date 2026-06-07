import Foundation

struct Config: Codable {
    var showHelp: Bool = true
    var wordWrap: Bool = true
    var renderMarkdown: Bool = true
    // Optional so configs written before this field still decode.
    var scrollPastEnd: Bool? = true
    var fullTable: Bool? = true
    // Stored as the raw string so renaming/removing a theme can't make the
    // whole config fail to decode; unknown values just fall back to default.
    var theme: String? = nil
    var appearance: String? = nil

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
            let data = try JSONEncoder().encode(self)
            try data.write(to: URL(fileURLWithPath: Config.configPath))
        } catch { }
    }
}
