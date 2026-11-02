import Foundation

enum LLMProvider: String, Codable {
    case lmStudio
    /// Saved under its old name, so configs from before API keys keep loading.
    case openAI = "openaiOAuth"
    case openRouter
    case mock

    var displayName: String {
        switch self {
        case .lmStudio:    return "LM Studio"
        case .openAI:      return "OpenAI"
        case .openRouter:  return "OpenRouter"
        case .mock:        return "Mock (offline)"
        }
    }
}
