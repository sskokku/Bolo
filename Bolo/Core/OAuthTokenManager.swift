import Foundation
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "OAuthTokenManager")

// MARK: - Stored Token State

/// OAuth2 tokens persisted in the Keychain as JSON.
struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userEmail: String?
    let scopes: [String]
}

// MARK: - Token Check Result

/// Result of checking the current token state (synchronous).
private enum TokenCheckResult: Sendable {
    case valid(String)
    case needsRefresh(refreshToken: String)
    case noTokens
    case alreadyRefreshing
}

// MARK: - OAuth Token Manager

/// Manages OAuth2 token lifecycle: storage, retrieval, and automatic refresh.
///
/// Thread-safe via a serial DispatchQueue for state mutations.
/// The primary API is `validAccessToken()` which returns a fresh access token,
/// transparently refreshing when the current one is close to expiry.
final class OAuthTokenManager: @unchecked Sendable {

    static let shared = OAuthTokenManager()

    // MARK: - Constants

    private static let tokensKeychainKey = "vertex_ai_oauth_tokens"
    /// Refresh the token if it expires within this many seconds.
    private static let refreshBufferSeconds: TimeInterval = 300 // 5 minutes

    // MARK: - State (protected by stateQueue)

    private let stateQueue = DispatchQueue(label: "com.bolo.oauth.state")
    private var tokens: OAuthTokens?
    private var refreshTask: Task<String, Error>?
    private var _clientID: String = ""

    var clientID: String {
        get { stateQueue.sync { _clientID } }
        set { stateQueue.sync { _clientID = newValue } }
    }

    // MARK: - Init

    private init() {
        tokens = loadTokensFromKeychain()
        if tokens != nil {
            logger.info("Loaded existing OAuth tokens from Keychain")
        }
    }

    // MARK: - Public API

    /// Returns a valid access token, refreshing if needed.
    /// This is the primary API — `VertexAIClient` calls this before each request.
    func validAccessToken() async throws -> String {
        // Step 1: Check state synchronously
        let checkResult: TokenCheckResult = stateQueue.sync {
            guard let currentTokens = tokens else {
                return .noTokens
            }

            if currentTokens.expiresAt.timeIntervalSinceNow > Self.refreshBufferSeconds {
                return .valid(currentTokens.accessToken)
            }

            if refreshTask != nil {
                return .alreadyRefreshing
            }

            return .needsRefresh(refreshToken: currentTokens.refreshToken)
        }

        // Step 2: Act on result outside the lock
        switch checkResult {
        case .valid(let token):
            return token

        case .noTokens:
            throw VertexAIError.notSignedIn

        case .alreadyRefreshing:
            // Wait for the existing refresh task
            let task: Task<String, Error>? = stateQueue.sync { refreshTask }
            if let task {
                return try await task.value
            }
            throw VertexAIError.notSignedIn

        case .needsRefresh(let refreshToken):
            // Create and store the refresh task
            let task = Task<String, Error> { [weak self] in
                guard let self else { throw VertexAIError.notSignedIn }
                return try await self.performTokenRefresh(refreshToken: refreshToken)
            }
            stateQueue.sync { self.refreshTask = task }

            do {
                let newToken = try await task.value
                stateQueue.sync { self.refreshTask = nil }
                return newToken
            } catch {
                stateQueue.sync { self.refreshTask = nil }
                throw error
            }
        }
    }

    /// Store tokens after initial OAuth2 code exchange.
    func storeTokens(_ newTokens: OAuthTokens) {
        stateQueue.sync {
            tokens = newTokens
        }
        saveTokensToKeychain(newTokens)
        logger.info("OAuth tokens stored — email: \(newTokens.userEmail ?? "unknown")")
    }

    /// Clear all tokens (sign-out).
    func clearTokens() {
        stateQueue.sync {
            tokens = nil
            refreshTask?.cancel()
            refreshTask = nil
        }
        KeychainHelper.delete(Self.tokensKeychainKey)
        logger.info("OAuth tokens cleared (signed out)")
    }

    /// Whether the user is currently signed in.
    var isSignedIn: Bool {
        stateQueue.sync { tokens != nil }
    }

    /// The signed-in user's email (from the stored tokens).
    var userEmail: String? {
        stateQueue.sync { tokens?.userEmail }
    }

    // MARK: - Private: Token Refresh

    private func performTokenRefresh(refreshToken: String) async throws -> String {
        let errorLog = ErrorLogger.shared
        errorLog.logInfo(category: .api, message: "Refreshing OAuth2 access token")

        let currentClientID = self.clientID
        guard !currentClientID.isEmpty else {
            errorLog.logError(category: .api, message: "Cannot refresh token — OAuth Client ID not configured")
            throw VertexAIError.invalidConfiguration("OAuth Client ID not configured")
        }

        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(currentClientID)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            errorLog.logError(category: .api, message: "Token refresh network error", error: error)
            throw VertexAIError.tokenRefreshFailed(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexAIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            errorLog.logError(category: .api, message: "Token refresh failed: HTTP \(httpResponse.statusCode) — \(String(errorBody.prefix(500)))")
            throw VertexAIError.tokenRefreshFailed(
                NSError(domain: "OAuthTokenManager", code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Token refresh failed (HTTP \(httpResponse.statusCode)). Please sign in again."])
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let newAccessToken = json["access_token"] as? String else {
            errorLog.logError(category: .api, message: "Token refresh response missing access_token")
            throw VertexAIError.invalidResponse
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        // Build updated tokens (keep existing refresh token and email)
        let updatedTokens: OAuthTokens = stateQueue.sync {
            let existing = tokens
            let updated = OAuthTokens(
                accessToken: newAccessToken,
                refreshToken: existing?.refreshToken ?? refreshToken,
                expiresAt: expiresAt,
                userEmail: existing?.userEmail,
                scopes: existing?.scopes ?? []
            )
            tokens = updated
            return updated
        }

        saveTokensToKeychain(updatedTokens)
        errorLog.logInfo(category: .api, message: "OAuth2 access token refreshed — expires in \(expiresIn)s")

        return newAccessToken
    }

    // MARK: - Private: Keychain Persistence

    private func saveTokensToKeychain(_ tokens: OAuthTokens) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tokens),
              let jsonString = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode OAuth tokens for Keychain")
            return
        }
        KeychainHelper.save(jsonString, for: Self.tokensKeychainKey)
    }

    private func loadTokensFromKeychain() -> OAuthTokens? {
        guard let jsonString = KeychainHelper.load(Self.tokensKeychainKey),
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OAuthTokens.self, from: data)
    }
}
