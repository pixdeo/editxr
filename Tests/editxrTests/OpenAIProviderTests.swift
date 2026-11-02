import XCTest
@testable import editxr

/// OpenAI authenticates with an API key, like OpenRouter. ChatGPT sign-in
/// tokens are refused by the API, so nothing here depends on one.
final class OpenAIProviderTests: XCTestCase {

    func testAKeyAndModelReachTheOpenAIEndpoint() {
        let service = LLMService()
        service.setProvider(.openAI)
        service.openAIKey = "sk-test"
        service.openAIModel = "gpt-test"
        let endpoint = service.endpointForTest
        XCTAssertEqual(endpoint.base, "https://api.openai.com")
        XCTAssertEqual(endpoint.model, "gpt-test")
        XCTAssertEqual(endpoint.bearer, "sk-test")
    }

    func testAnEmptyModelFallsBackToADefault() {
        let service = LLMService()
        service.setProvider(.openAI)
        service.openAIModel = ""
        XCTAssertFalse(service.endpointForTest.model.isEmpty)
    }

    func testARequestWithoutAKeyAsksForOneInsteadOfCallingOpenAI() {
        let service = LLMService()
        service.setProvider(.openAI)
        let answered = expectation(description: "the request was refused")
        service.completeStreaming(prompt: "fix", onChunk: { _ in }) { result in
            if case .failure(.connectionFailed(let message)) = result {
                XCTAssertTrue(message.contains("OpenAI"))
                answered.fulfill()
            }
        }
        wait(for: [answered], timeout: 2)
    }

    func testAConfigSavedWithTheOldProviderStillLoads() throws {
        // Written by every version that had OpenAI sign-in. Failing to decode
        // would reset the whole config, not just the provider.
        let json = #"{"wordWrap":true,"renderMarkdown":true,"llmProvider":"openaiOAuth","openRouterKey":"kept","openAIAccessToken":"stale"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.llmProvider, .openAI)
        XCTAssertEqual(config.openRouterKey, "kept")
    }

    func testOldSignInTokensAreDroppedOnTheNextSave() throws {
        let json = #"{"wordWrap":true,"renderMarkdown":true,"llmProvider":"openaiOAuth","openAIAccessToken":"stale","openAIRefreshToken":"stale"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let saved = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        XCTAssertFalse(saved.contains("stale"))
    }

    func testThePaletteOffersOpenAIWithoutASignIn() {
        let app = EditorApp(states: [EditorState(filePath: "/tmp/editxr-openai-\(UUID().uuidString).md")])
        let titles = app.llmProviderTitlesForTest()
        XCTAssertTrue(titles.contains("OpenAI"))
        XCTAssertFalse(titles.contains("Sign in to OpenAI"))
    }
}
