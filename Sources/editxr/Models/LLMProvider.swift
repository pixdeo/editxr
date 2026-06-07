import Foundation

enum LLMProvider: String, Codable {
    case lmStudio
    case openaiOAuth
    case openRouter
    case mock

    var displayName: String {
        switch self {
        case .lmStudio:    return "LM Studio"
        case .openaiOAuth: return "OpenAI"
        case .openRouter:  return "OpenRouter"
        case .mock:        return "Mock (offline)"
        }
    }
}
