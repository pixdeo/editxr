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
    private var currentTask: URLSessionDataTask?
    
    init(config: LLMConfig = LLMConfig()) {
        self.config = config
    }
    
    /// Cancel any ongoing request
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    /// Check if LM Studio is reachable
    func checkConnection(completion: @escaping (Bool) -> Void) {
        let url = URL(string: "\(config.baseURL)/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        
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
        let url = URL(string: "\(config.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
        var messages: [LLMChatMessage] = []
        
        let system = systemPrompt ?? "You are a writing assistant. Output ONLY the requested text. No explanations, no reasoning, no analysis, no numbered steps. Just the direct result."
        messages.append(LLMChatMessage(role: "system", content: system))
        
        var userContent = prompt
        if !context.isEmpty {
            userContent = "Context:\n\"\"\"\n\(context)\n\"\"\"\n\nTask: \(prompt)"
        }
        messages.append(LLMChatMessage(role: "user", content: userContent))
        
        let body = LLMChatRequest(
            model: config.model,
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
        let url = URL(string: "\(config.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        
        var messages: [LLMChatMessage] = []
        
        let system = systemPrompt ?? "You are a writing assistant. Output ONLY the requested text. No explanations, no reasoning, no analysis, no numbered steps. Just the direct result."
        messages.append(LLMChatMessage(role: "system", content: system))
        
        var userContent = prompt
        if !context.isEmpty {
            userContent = "Context:\n\"\"\"\n\(context)\n\"\"\"\n\nTask: \(prompt)"
        }
        messages.append(LLMChatMessage(role: "user", content: userContent))
        
        let body = LLMChatRequest(
            model: config.model,
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
    private var buffer = ""
    
    init(onChunk: @escaping (String) -> Void, onComplete: @escaping (Result<Void, LLMError>) -> Void) {
        self.onChunk = onChunk
        self.onComplete = onComplete
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text
        
        while let newlineRange = buffer.range(of: "\n") {
            let line = String(buffer[..<newlineRange.lowerBound])
            buffer = String(buffer[newlineRange.upperBound...])
            
            processLine(line)
        }
    }
    
    private func processLine(_ line: String) {
        guard line.hasPrefix("data: ") else { return }
        let json = String(line.dropFirst(6))
        
        if json == "[DONE]" {
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
