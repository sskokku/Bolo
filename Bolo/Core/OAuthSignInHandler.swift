import Foundation
import AppKit
import Network
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "OAuthSignIn")

// MARK: - OAuth Errors

enum OAuthError: Error, LocalizedError {
    case serverStartFailed
    case authorizationDenied(String)
    case tokenExchangeFailed(String)
    case invalidResponse
    case timeout
    case invalidState

    var errorDescription: String? {
        switch self {
        case .serverStartFailed:
            return "Failed to start local authentication server"
        case .authorizationDenied(let reason):
            return "Authorization denied: \(reason)"
        case .tokenExchangeFailed(let reason):
            return "Token exchange failed: \(reason)"
        case .invalidResponse:
            return "Invalid response from Google"
        case .timeout:
            return "Sign-in timed out — please try again"
        case .invalidState:
            return "Invalid state parameter — possible CSRF attack"
        }
    }
}

// MARK: - OAuth Sign-In Handler

/// Handles the OAuth2 Authorization Code flow with PKCE for desktop apps.
///
/// Flow:
/// 1. Start a local HTTP server on a random available port (loopback only)
/// 2. Open the browser to Google's authorization URL
/// 3. Receive the auth code callback on the loopback server
/// 4. Exchange the code for access + refresh tokens
/// 5. Return the tokens for storage via OAuthTokenManager
final class OAuthSignInHandler: Sendable {

    private let clientID: String
    private let scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let timeoutSeconds: TimeInterval = 120

    init(clientID: String) {
        self.clientID = clientID
    }

    /// Initiates the sign-in flow. Returns the obtained tokens.
    func signIn() async throws -> OAuthTokens {
        let errorLog = ErrorLogger.shared
        errorLog.logInfo(category: .api, message: "Starting OAuth2 sign-in flow")

        // Generate PKCE pair
        let pkce = generatePKCE()

        // Generate state for CSRF protection
        let state = UUID().uuidString

        // Start loopback server
        let server = LoopbackServer()
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)"

        errorLog.logInfo(category: .api, message: "OAuth loopback server started on port \(port)")

        defer {
            server.stop()
        }

        // Build authorization URL
        let authorizationURL = buildAuthorizationURL(
            redirectURI: redirectURI,
            codeChallenge: pkce.challenge,
            state: state
        )

        // Open browser on main thread
        await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }

        // Capture timeout for sendable closure
        let timeout = timeoutSeconds

        // Wait for callback with timeout
        let callbackResult: (code: String, returnedState: String)
        do {
            callbackResult = try await withThrowingTaskGroup(of: (String, String).self) { group in
                group.addTask {
                    try await server.waitForCallback()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw OAuthError.timeout
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch is CancellationError {
            throw OAuthError.timeout
        }

        // Verify state
        guard callbackResult.returnedState == state else {
            errorLog.logError(category: .api, message: "OAuth state mismatch — possible CSRF")
            throw OAuthError.invalidState
        }

        // Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(
            code: callbackResult.code,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURI
        )

        errorLog.logInfo(category: .api, message: "OAuth2 sign-in successful — email: \(tokens.userEmail ?? "unknown")")
        return tokens
    }

    // MARK: - Private: PKCE

    private func generatePKCE() -> (verifier: String, challenge: String) {
        // 32 random bytes → base64url → code_verifier
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        let verifier = Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // SHA-256 of verifier → base64url → code_challenge
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return (verifier, challenge)
    }

    // MARK: - Private: URL Building

    private func buildAuthorizationURL(redirectURI: String, codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    // MARK: - Private: Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String, redirectURI: String) async throws -> OAuthTokens {
        let errorLog = ErrorLogger.shared

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyComponents = [
            "code=\(percentEncode(code))",
            "client_id=\(percentEncode(clientID))",
            "redirect_uri=\(percentEncode(redirectURI))",
            "grant_type=authorization_code",
            "code_verifier=\(percentEncode(codeVerifier))"
        ]
        request.httpBody = bodyComponents.joined(separator: "&").data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            errorLog.logError(category: .api, message: "Token exchange network error", error: error)
            throw OAuthError.tokenExchangeFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            errorLog.logError(category: .api, message: "Token exchange failed: HTTP \(httpResponse.statusCode) — \(String(errorBody.prefix(500)))")
            throw OAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidResponse
        }

        guard let refreshToken = json["refresh_token"] as? String else {
            errorLog.logError(category: .api, message: "No refresh_token in response — ensure access_type=offline and prompt=consent")
            throw OAuthError.tokenExchangeFailed("No refresh token received. Please try signing in again.")
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let scopeString = json["scope"] as? String ?? ""

        // Extract email from ID token if present
        var userEmail: String?
        if let idToken = json["id_token"] as? String {
            userEmail = extractEmailFromIDToken(idToken)
        }

        // If no email from ID token, try the userinfo endpoint
        if userEmail == nil {
            userEmail = try? await fetchUserEmail(accessToken: accessToken)
        }

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            userEmail: userEmail,
            scopes: scopeString.components(separatedBy: " ")
        )
    }

    // MARK: - Private: Helpers

    private func percentEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }

    /// Extract the email claim from a JWT ID token (base64-decode the payload).
    private func extractEmailFromIDToken(_ idToken: String) -> String? {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }

        var payload = parts[1]
        // Pad base64 if needed
        while payload.count % 4 != 0 {
            payload += "="
        }
        // Convert from base64url to base64
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            return nil
        }
        return email
    }

    /// Fetch the user's email from the Google userinfo endpoint.
    private func fetchUserEmail(accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["email"] as? String
    }
}

// MARK: - Loopback HTTP Server

/// Minimal HTTP server on 127.0.0.1 that handles the OAuth2 redirect callback.
/// Uses Network.framework (NWListener) for a lightweight, dependency-free implementation.
private final class LoopbackServer: @unchecked Sendable {

    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private let queue = DispatchQueue(label: "com.bolo.oauth.loopback")

    /// Start the server and return the assigned port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw OAuthError.serverStartFailed
        }
        self.listener = listener

        return try await withCheckedThrowingContinuation { portContinuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        portContinuation.resume(returning: port.rawValue)
                    } else {
                        portContinuation.resume(throwing: OAuthError.serverStartFailed)
                    }
                case .failed(let error):
                    portContinuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: queue)
        }
    }

    /// Wait for the OAuth callback. Returns (code, state).
    func waitForCallback() async throws -> (String, String) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Stop the server.
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            guard let requestString = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the GET request line to extract query parameters
            let result = self.parseCallback(requestString)

            // Send a response to the browser
            let responseHTML: String
            if result != nil {
                responseHTML = """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 60px;">
                <h2>Sign-in successful!</h2>
                <p>You can close this window and return to Bolo.</p>
                </body></html>
                """
            } else {
                responseHTML = """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 60px;">
                <h2>Sign-in failed</h2>
                <p>Please close this window and try again in Bolo.</p>
                </body></html>
                """
            }

            let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n\(responseHTML)"
            connection.send(content: httpResponse.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            // Resolve the continuation
            if let (code, state) = result {
                self.continuation?.resume(returning: (code, state))
                self.continuation = nil
            } else {
                self.continuation?.resume(throwing: OAuthError.authorizationDenied("No authorization code received"))
                self.continuation = nil
            }
        }
    }

    /// Parse the OAuth callback from the HTTP request.
    /// Returns (code, state) or nil if the request doesn't contain an auth code.
    private func parseCallback(_ request: String) -> (String, String)? {
        // Extract the request line: "GET /?code=...&state=... HTTP/1.1"
        guard let firstLine = request.components(separatedBy: "\r\n").first,
              let pathStart = firstLine.range(of: " /"),
              let pathEnd = firstLine.range(of: " HTTP") else {
            return nil
        }

        let path = String(firstLine[pathStart.upperBound..<pathEnd.lowerBound])

        // Check for error response
        if path.contains("error=") {
            return nil
        }

        // Parse query parameters
        guard let components = URLComponents(string: "http://localhost\(path)"),
              let queryItems = components.queryItems else {
            return nil
        }

        let code = queryItems.first { $0.name == "code" }?.value
        let state = queryItems.first { $0.name == "state" }?.value

        guard let code, let state else { return nil }
        return (code, state)
    }
}
