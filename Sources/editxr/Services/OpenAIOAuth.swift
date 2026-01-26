import Foundation
import CryptoKit
import Network

struct OpenAIOAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double?
}

final class OpenAIOAuth {
    struct Config {
        var authorizeURL: String
        var tokenURL: String
        var clientId: String
        var scope: String
        var audience: String?
    }

    enum OAuthError: Error, LocalizedError {
        case missingClientId
        case invalidURL
        case serverFailed(String)
        case cancelled
        case tokenExchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingClientId:
                return "Missing OPENAI_OAUTH_CLIENT_ID"
            case .invalidURL:
                return "Invalid OAuth URL"
            case .serverFailed(let msg):
                return msg
            case .cancelled:
                return "Cancelled"
            case .tokenExchangeFailed(let msg):
                return msg
            }
        }
    }

    private var listener: NWListener?
    private var pendingState: String?

    func start(
        onUpdate: @escaping (_ url: String, _ message: String) -> Void,
        completion: @escaping (Result<OpenAIOAuthTokens, OAuthError>) -> Void
    ) {
        guard let cfg = loadConfig() else {
            completion(.failure(.missingClientId))
            return
        }

        let verifier = randomVerifier()
        let challenge = codeChallengeS256(verifier)
        let state = randomState()
        pendingState = state

        startCallbackServer { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let callback):
                guard callback.state == state else {
                    completion(.failure(.serverFailed("OAuth state mismatch")))
                    return
                }

                self.exchangeCode(
                    cfg: cfg,
                    code: callback.code,
                    redirectURI: callback.redirectURI,
                    codeVerifier: verifier
                ) { tokenResult in
                    completion(tokenResult)
                }
            }
        } onReady: { redirectURI, localURL in
            let authURL = self.buildAuthorizeURL(
                cfg: cfg,
                redirectURI: redirectURI,
                codeChallenge: challenge,
                state: state
            )

            onUpdate(authURL, "Open browser to authorize")
            self.openInBrowser(authURL)
            onUpdate(localURL, "Waiting for callback")
        }
    }

    func cancel() {
        listener?.cancel()
        listener = nil
        pendingState = nil
    }

    private func loadConfig() -> Config? {
        let env = ProcessInfo.processInfo.environment
        guard let clientId = env["OPENAI_OAUTH_CLIENT_ID"], !clientId.isEmpty else {
            return nil
        }

        let authorizeURL = env["OPENAI_OAUTH_AUTHORIZE_URL"] ?? "https://auth.openai.com/oauth/authorize"
        let tokenURL = env["OPENAI_OAUTH_TOKEN_URL"] ?? "https://auth.openai.com/oauth/token"
        let scope = env["OPENAI_OAUTH_SCOPE"] ?? "openid profile email"
        let audience = env["OPENAI_OAUTH_AUDIENCE"]
        return Config(authorizeURL: authorizeURL, tokenURL: tokenURL, clientId: clientId, scope: scope, audience: audience)
    }

    private func openInBrowser(_ url: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]
        try? proc.run()
    }

    private func buildAuthorizeURL(cfg: Config, redirectURI: String, codeChallenge: String, state: String) -> String {
        var comps = URLComponents(string: cfg.authorizeURL)
        var items: [URLQueryItem] = []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: cfg.clientId))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
        items.append(URLQueryItem(name: "scope", value: cfg.scope))
        items.append(URLQueryItem(name: "state", value: state))
        items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        if let audience = cfg.audience {
            items.append(URLQueryItem(name: "audience", value: audience))
        }
        comps?.queryItems = items
        return comps?.url?.absoluteString ?? cfg.authorizeURL
    }

    private struct CallbackResult {
        var code: String
        var state: String
        var redirectURI: String
    }

    private func startCallbackServer(
        onCallback: @escaping (Result<CallbackResult, OAuthError>) -> Void,
        onReady: @escaping (_ redirectURI: String, _ localURL: String) -> Void
    ) {
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener

            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                self.receiveRequest(on: conn) { req in
                    let response = self.htmlResponse("You can close this window.")
                    conn.send(content: response, completion: .contentProcessed { _ in
                        conn.cancel()
                    })

                    self.listener?.cancel()
                    self.listener = nil

                    guard let code = req["code"], let state = req["state"] else {
                        onCallback(.failure(.serverFailed("Missing code/state")))
                        return
                    }

                    let redirectURI = "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/callback"
                    onCallback(.success(CallbackResult(code: code, state: state, redirectURI: redirectURI)))
                }
            }

            listener.stateUpdateHandler = { st in
                if case .ready = st {
                    let port = listener.port?.rawValue ?? 0
                    let redirectURI = "http://127.0.0.1:\(port)/callback"
                    onReady(redirectURI, redirectURI)
                }
            }

            listener.start(queue: .main)
        } catch {
            onCallback(.failure(.serverFailed(error.localizedDescription)))
        }
    }

    private func receiveRequest(on conn: NWConnection, completion: @escaping ([String: String]) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            guard let data = data, let str = String(data: data, encoding: .utf8) else {
                completion([:])
                return
            }
            let firstLine = str.split(separator: "\n").first.map(String.init) ?? ""
            // GET /callback?code=...&state=... HTTP/1.1
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                completion([:])
                return
            }
            let path = String(parts[1])
            guard let url = URL(string: "http://localhost\(path)"),
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                completion([:])
                return
            }
            var dict: [String: String] = [:]
            for item in comps.queryItems ?? [] {
                if let v = item.value {
                    dict[item.name] = v
                }
            }
            completion(dict)
        }
    }

    private func htmlResponse(_ message: String) -> Data {
        let html = """
        <!doctype html>
        <html>
          <head><meta charset=\"utf-8\"><title>editxr</title></head>
          <body>
            <p>\(message)</p>
            <script>window.close();</script>
          </body>
        </html>
        """

        let body = html.data(using: .utf8) ?? Data()
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var res = Data(header.utf8)
        res.append(body)
        return res
    }

    private struct TokenResponse: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let token_type: String?
    }

    private func exchangeCode(
        cfg: Config,
        code: String,
        redirectURI: String,
        codeVerifier: String,
        completion: @escaping (Result<OpenAIOAuthTokens, OAuthError>) -> Void
    ) {
        guard let url = URL(string: cfg.tokenURL) else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var items: [URLQueryItem] = []
        items.append(URLQueryItem(name: "grant_type", value: "authorization_code"))
        items.append(URLQueryItem(name: "client_id", value: cfg.clientId))
        items.append(URLQueryItem(name: "code", value: code))
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
        items.append(URLQueryItem(name: "code_verifier", value: codeVerifier))

        var comps = URLComponents()
        comps.queryItems = items
        request.httpBody = comps.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(.tokenExchangeFailed(error.localizedDescription)))
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.failure(.tokenExchangeFailed("No HTTP response")))
                }
                return
            }
            guard (200...299).contains(http.statusCode), let data = data else {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "HTTP \(http.statusCode)"
                DispatchQueue.main.async {
                    completion(.failure(.tokenExchangeFailed(msg)))
                }
                return
            }
            do {
                let token = try JSONDecoder().decode(TokenResponse.self, from: data)
                let expiresAt: Double?
                if let expiresIn = token.expires_in {
                    expiresAt = Date().timeIntervalSince1970 + expiresIn
                } else {
                    expiresAt = nil
                }
                DispatchQueue.main.async {
                    completion(.success(OpenAIOAuthTokens(accessToken: token.access_token, refreshToken: token.refresh_token, expiresAt: expiresAt)))
                }
            } catch {
                let msg = String(data: data, encoding: .utf8) ?? "Invalid token response"
                DispatchQueue.main.async {
                    completion(.failure(.tokenExchangeFailed(msg)))
                }
            }
        }.resume()
    }

    private func randomVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return base64URLEncode(Data(bytes))
    }

    private func randomState() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        return base64URLEncode(Data(bytes))
    }

    private func codeChallengeS256(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
