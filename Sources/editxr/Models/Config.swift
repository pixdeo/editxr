import Foundation

struct Config: Codable {
    var showHelp: Bool = true
    var wordWrap: Bool = true
    var renderMarkdown: Bool = true
    // Optional so configs written before this field still decode.
    var scrollPastEnd: Bool? = true
    var fullTable: Bool? = true

    var llmProvider: LLMProvider = .lmStudio
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
