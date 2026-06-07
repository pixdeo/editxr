import Foundation

/// Configuration for LLM provider
struct LLMConfig {
    var host: String = "localhost"
    var port: Int = 1234
    var model: String = "qwen2.5-7b-instruct"
    var maxTokens: Int = 1024
    var temperature: Float = 0.7
    
    var baseURL: String {
        "http://\(host):\(port)"
    }
    
    static func load(from path: String? = nil) -> LLMConfig {
        return LLMConfig()
    }
}

/// Request/Response models for LM Studio OpenAI-compatible API
struct LLMChatMessage: Codable {
    let role: String
    let content: String
}

struct LLMChatRequest: Codable {
    let model: String
    let messages: [LLMChatMessage]
    let temperature: Float
    let stream: Bool
}

struct LLMChatChoice: Codable {
    let message: LLMChatMessage
    let finish_reason: String?
}

struct LLMChatResponse: Codable {
    let choices: [LLMChatChoice]
}

struct LLMStreamChunk: Codable {
    struct Delta: Codable {
        let content: String?
    }
    struct Choice: Codable {
        let delta: Delta
        let finish_reason: String?
    }
    let choices: [Choice]
}

/// Error types for LLM operations
enum LLMError: Error, LocalizedError {
    case connectionFailed(String)
    case invalidResponse
    case serverError(Int, String)
    case timeout
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .invalidResponse: return "Invalid response from server"
        case .serverError(let code, let msg): return "Server error \(code): \(msg)"
        case .timeout: return "Request timed out"
        case .cancelled: return "Request cancelled"
        }
    }
}

/// Result of an LLM completion
struct LLMResult {
    let text: String
    let finishReason: String?
}

/// Service for communicating with LM Studio via OpenAI-compatible API
class LLMService {
    var config: LLMConfig
    var provider: LLMProvider = .lmStudio
    var openAIAccessToken: String? = nil
    var openRouterKey: String? = nil
    var openRouterModel: String? = nil

    private var currentTask: URLSessionDataTask?
    private var mockCancelled = false

    /// Default instruction for the section-edit flow: replace the section with
    /// the model's output, so it must return the complete updated section only.
    static let editSystemPrompt = """
    You are editing one section of a Markdown document. Apply the user's \
    instruction and return the COMPLETE updated section as Markdown. Output \
    ONLY the Markdown for the section — no surrounding code fences, no \
    commentary, no explanations, no reasoning, no "Here is" prefixes.
    """

    init(config: LLMConfig = LLMConfig()) {
        self.config = config
    }

    func setProvider(_ provider: LLMProvider, openAIAccessToken: String?) {
        self.provider = provider
        self.openAIAccessToken = openAIAccessToken
    }

    /// Resolve the OpenAI-compatible endpoint for the current provider.
    /// `.mock` is handled before this is ever called.
    private func endpoint() -> (base: String, model: String, bearer: String?) {
        switch provider {
        case .lmStudio:
            return (config.baseURL, config.model, nil)
        case .openaiOAuth:
            return ("https://api.openai.com",
                    ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-4o-mini",
                    openAIAccessToken)
        case .openRouter:
            return ("https://openrouter.ai/api",
                    (openRouterModel?.isEmpty == false ? openRouterModel! : "openai/gpt-4o-mini"),
                    openRouterKey)
        case .mock:
            return ("", "mock", nil)
        }
    }

    /// Providers that authenticate with a Bearer token (and require one).
    private var requiresBearer: Bool {
        provider == .openaiOAuth || provider == .openRouter
    }

    /// Cancel any ongoing request
    func cancel() {
        mockCancelled = true
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Offline mock

    /// Deterministic offline transform so the edit-review flow is testable
    /// without any backend: upper-cases each non-empty line so a diff shows.
    static func mockTransform(context: String, prompt: String) -> String {
        context.components(separatedBy: "\n")
            .map { $0.isEmpty ? $0 : $0.uppercased() }
            .joined(separator: "\n")
    }

    private func runMock(context: String, prompt: String,
                         onChunk: @escaping (String) -> Void,
                         onComplete: @escaping (Result<Void, LLMError>) -> Void) {
        mockCancelled = false
        let chars = Array(LLMService.mockTransform(context: context, prompt: prompt))
        func emit(_ i: Int) {
            if mockCancelled { onComplete(.failure(.cancelled)); return }
            if i >= chars.count { onComplete(.success(())); return }
            let end = min(i + 6, chars.count)
            onChunk(String(chars[i..<end]))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { emit(end) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { emit(0) }
    }
    
    /// Check if LM Studio is reachable
    func checkConnection(completion: @escaping (Bool) -> Void) {
        if provider == .mock { completion(true); return }

        let ep = endpoint()
        let url = URL(string: "\(ep.base)/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        if requiresBearer, let token = ep.bearer, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse {
                completion(httpResponse.statusCode == 200)
            } else {
                completion(false)
            }
        }.resume()
    }
    
    /// Send a completion request (non-streaming)
    func complete(
        prompt: String,
        context: String = "",
        systemPrompt: String? = nil,
        completion: @escaping (Result<LLMResult, LLMError>) -> Void
    ) {
        if provider == .mock {
            completion(.success(LLMResult(text: LLMService.mockTransform(context: context, prompt: prompt), finishReason: "stop")))
            return
        }

        let ep = endpoint()
        let url = URL(string: "\(ep.base)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        if requiresBearer {
            guard let token = ep.bearer, !token.isEmpty else {
                completion(.failure(.connectionFailed("\(provider.displayName) not configured")))
                return
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var messages: [LLMChatMessage] = []

        let system = systemPrompt ?? LLMService.editSystemPrompt
        messages.append(LLMChatMessage(role: "system", content: system))

        var userContent = prompt
        if !context.isEmpty {
            userContent = "Section to edit:\n\"\"\"\n\(context)\n\"\"\"\n\nInstruction: \(prompt)"
        }
        messages.append(LLMChatMessage(role: "user", content: userContent))

        let body = LLMChatRequest(
            model: ep.model,
            messages: messages,
            temperature: config.temperature,
            stream: false
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            completion(.failure(.invalidResponse))
            return
        }
        
        currentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.currentTask = nil
            
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    completion(.failure(.cancelled))
                } else if error.code == NSURLErrorTimedOut {
                    completion(.failure(.timeout))
                } else {
                    completion(.failure(.connectionFailed(error.localizedDescription)))
                }
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMsg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
                completion(.failure(.serverError(httpResponse.statusCode, errorMsg)))
                return
            }
            
            guard let data = data else {
                completion(.failure(.invalidResponse))
                return
            }
            
            do {
                let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)
                if let choice = response.choices.first {
                    completion(.success(LLMResult(
                        text: choice.message.content,
                        finishReason: choice.finish_reason
                    )))
                } else {
                    completion(.failure(.invalidResponse))
                }
            } catch {
                completion(.failure(.invalidResponse))
            }
        }
        currentTask?.resume()
    }
    
    /// Send a streaming completion request
    func completeStreaming(
        prompt: String,
        context: String = "",
        systemPrompt: String? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<Void, LLMError>) -> Void
    ) {
        if provider == .mock {
            runMock(context: context, prompt: prompt, onChunk: onChunk, onComplete: onComplete)
            return
        }

        let ep = endpoint()
        let url = URL(string: "\(ep.base)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        if requiresBearer {
            guard let token = ep.bearer, !token.isEmpty else {
                onComplete(.failure(.connectionFailed("\(provider.displayName) not configured")))
                return
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var messages: [LLMChatMessage] = []

        let system = systemPrompt ?? LLMService.editSystemPrompt
        messages.append(LLMChatMessage(role: "system", content: system))

        var userContent = prompt
        if !context.isEmpty {
            userContent = "Section to edit:\n\"\"\"\n\(context)\n\"\"\"\n\nInstruction: \(prompt)"
        }
        messages.append(LLMChatMessage(role: "user", content: userContent))

        let body = LLMChatRequest(
            model: ep.model,
            messages: messages,
            temperature: config.temperature,
            stream: true
        )
        
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            onComplete(.failure(.invalidResponse))
            return
        }
        
        let session = URLSession(configuration: .default, delegate: StreamDelegate(
            onChunk: onChunk,
            onComplete: onComplete
        ), delegateQueue: nil)
        
        currentTask = session.dataTask(with: request)
        currentTask?.resume()
    }
    
    /// Improve text with a specific instruction
    func improve(
        text: String,
        instruction: String,
        completion: @escaping (Result<LLMResult, LLMError>) -> Void
    ) {
        let systemPrompt = """
        You are a writing assistant. Output ONLY the improved text.
        No explanations. No reasoning. No analysis. No numbered steps. No "Here is" prefixes.
        Just the direct result. Maintain original format.
        """
        
        let prompt = """
        Improve the following text: \(instruction)
        
        Text to improve:
        \(text)
        """
        
        complete(prompt: prompt, systemPrompt: systemPrompt, completion: completion)
    }
}

/// URLSession delegate for handling streaming responses
private class StreamDelegate: NSObject, URLSessionDataDelegate {
    private let onChunk: (String) -> Void
    private let onComplete: (Result<Void, LLMError>) -> Void
    // Buffer raw bytes (not String) so a multi-byte UTF-8 char split across two
    // network packets isn't lost — we only decode complete lines.
    private var buffer = Data()

    init(onChunk: @escaping (String) -> Void, onComplete: @escaping (Result<Void, LLMError>) -> Void) {
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        while let nl = buffer.firstIndex(of: 0x0A) {           // 0x0A == "\n"
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            if line.hasSuffix("\r") { line.removeLast() }       // tolerate CRLF framing
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        guard line.hasPrefix("data:") else { return }          // tolerate "data:" with or without a space
        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)

        if json == "[DONE]" || json.isEmpty {
            return
        }

        guard let data = json.data(using: .utf8) else { return }

        do {
            let chunk = try JSONDecoder().decode(LLMStreamChunk.self, from: data)
            if let content = chunk.choices.first?.delta.content {
                DispatchQueue.main.async {
                    self.onChunk(content)
                }
            }
        } catch { }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled {
                    self.onComplete(.failure(.cancelled))
                } else {
                    self.onComplete(.failure(.connectionFailed(error.localizedDescription)))
                }
            } else {
                self.onComplete(.success(()))
            }
        }
    }
}
