import Foundation
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "VertexAIClient")

// MARK: - Vertex AI Errors

enum VertexAIError: Error, LocalizedError {
    case notSignedIn
    case tokenRefreshFailed(Error)
    case invalidConfiguration(String)
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case accessDenied(userEmail: String?, projectID: String, reason: String?)
    case noTextInResponse
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in — please sign in with your Google account"
        case .tokenRefreshFailed(let error):
            return "Sign-in expired: \(error.localizedDescription)"
        case .invalidConfiguration(let message):
            return "Configuration error: \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Vertex AI"
        case .apiError(let message):
            return "API error: \(message)"
        case .accessDenied(let userEmail, let projectID, let reason):
            return Self.buildAccessDeniedMessage(userEmail: userEmail, projectID: projectID, reason: reason)
        case .noTextInResponse:
            return "No text returned from API"
        case .requestTooLarge:
            return "Audio file too large (max 20MB)"
        }
    }

    /// Builds a detailed, actionable 403 error message that the user can forward to their IT/GCP admin.
    private static func buildAccessDeniedMessage(userEmail: String?, projectID: String, reason: String?) -> String {
        var msg = "Access denied (403)"

        if let email = userEmail {
            msg += " for \(email)"
        }
        msg += " on project \(projectID)."

        if let reason, !reason.isEmpty {
            msg += "\n\nGoogle says: \(reason)"
        }

        msg += """

        \nAsk your GCP admin to verify:
        1. Your account has the \"Vertex AI User\" role (roles/aiplatform.user) on project \(projectID)
        2. The Vertex AI API (aiplatform.googleapis.com) is enabled in the project
        3. No Organization Policy is blocking Vertex AI access
        """

        if let email = userEmail {
            msg += "\n4. The account \(email) is in the correct Google Group (if using group-based IAM)"
        }

        return msg
    }
}

// MARK: - Vertex AI Client

/// Client for Google Vertex AI generateContent endpoint.
/// Uses OAuth2 Bearer tokens via OAuthTokenManager for per-user identity attribution.
struct VertexAIClient: TranscriptionProvider {

    private let projectID: String
    private let region: String
    private let model: String
    private let tokenManager: OAuthTokenManager

    init(projectID: String, region: String, model: String, tokenManager: OAuthTokenManager = .shared) {
        self.projectID = projectID
        self.region = region
        self.model = model
        self.tokenManager = tokenManager
    }

    // MARK: - TranscriptionProvider

    func transcribe(
        audio: Data,
        context: String? = nil,
        dictionary: [String] = []
    ) async throws -> String {

        guard audio.count < 20 * 1024 * 1024 else {
            ErrorLogger.shared.logError(category: .api, message: "Audio too large: \(audio.count) bytes (max 20MB)")
            throw VertexAIError.requestTooLarge
        }

        let base64Audio = audio.base64EncodedString()
        let systemPrompt = PromptBuilder.buildDictationPrompt(context: context, dictionary: dictionary)

        let request = GeminiRequest(
            contents: [
                Content(parts: [
                    Part(inlineData: InlineData(
                        mimeType: "audio/wav",
                        data: base64Audio
                    )),
                    Part(text: "Transcribe this audio.")
                ])
            ],
            systemInstruction: Content(parts: [
                Part(text: systemPrompt)
            ]),
            generationConfig: GenerationConfig(
                temperature: 0.1,
                maxOutputTokens: 2048
            )
        )

        return try await sendRequest(request)
    }

    func processCommand(
        selectedText: String,
        command: String
    ) async throws -> String {

        let systemPrompt = PromptBuilder.buildCommandPrompt()

        let request = GeminiRequest(
            contents: [
                Content(parts: [
                    Part(text: """
                    Selected text:
                    \(selectedText)

                    Command: \(command)
                    """)
                ])
            ],
            systemInstruction: Content(parts: [
                Part(text: systemPrompt)
            ]),
            generationConfig: GenerationConfig(
                temperature: 0.3,
                maxOutputTokens: 2048
            )
        )

        return try await sendRequest(request)
    }

    // MARK: - Private: Network

    private func sendRequest(_ request: GeminiRequest, isRetry: Bool = false) async throws -> String {
        let errorLog = ErrorLogger.shared

        let accessToken: String
        do {
            accessToken = try await tokenManager.validAccessToken()
        } catch {
            errorLog.logError(category: .api, message: "Failed to obtain access token", error: error)
            throw error // Already a VertexAIError
        }

        let urlString = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(projectID)/locations/\(region)/publishers/google/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            errorLog.logError(category: .api, message: "Invalid Vertex AI URL: \(urlString)")
            throw VertexAIError.invalidConfiguration("Invalid URL: \(urlString)")
        }

        errorLog.logInfo(category: .api, message: "Vertex AI request → \(urlString)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 60
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let bodySize = urlRequest.httpBody?.count ?? 0
        errorLog.logInfo(category: .api, message: "Request body size: \(bodySize) bytes")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            errorLog.logError(category: .api, message: "Vertex AI network error", error: error)
            throw VertexAIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            errorLog.logError(category: .api, message: "Invalid response — not HTTPURLResponse")
            throw VertexAIError.invalidResponse
        }

        errorLog.logInfo(category: .api, message: "Vertex AI response — HTTP \(httpResponse.statusCode), body: \(data.count) bytes")

        // Handle 401 with one retry (token may have expired despite buffer)
        if httpResponse.statusCode == 401 && !isRetry {
            errorLog.logWarning(category: .api, message: "Got 401 — attempting token refresh and retry")
            tokenManager.clearTokens()
            // Re-throw as not signed in so user re-authenticates
            throw VertexAIError.notSignedIn
        }

        if httpResponse.statusCode == 403 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            let reason = Self.parseGoogleErrorMessage(from: data)
            let userEmail = tokenManager.userEmail
            errorLog.logError(category: .api, message: "Vertex AI 403 for \(userEmail ?? "unknown") on project \(projectID) — \(reason ?? errorBody)")
            throw VertexAIError.accessDenied(
                userEmail: userEmail,
                projectID: projectID,
                reason: reason
            )
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            errorLog.logError(category: .api, message: "API error: HTTP \(httpResponse.statusCode) — \(String(errorBody.prefix(500)))")
            throw VertexAIError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        // Parse response — same format as Gemini Direct API
        let geminiResponse: GeminiResponse
        do {
            geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            errorLog.logError(category: .api, message: "JSON decode failed", error: error)
            throw VertexAIError.invalidResponse
        }

        guard let text = geminiResponse.candidates?.first?.content?.parts?.first?.text else {
            errorLog.logError(category: .api, message: "No text in response — candidates: \(geminiResponse.candidates?.count ?? 0)")
            throw VertexAIError.noTextInResponse
        }

        errorLog.logInfo(category: .api, message: "Vertex AI returned: \(String(text.prefix(100)))")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Error Parsing

    /// Parse the Google API error response to extract a human-readable message.
    ///
    /// Google API errors follow this structure:
    /// ```json
    /// {
    ///   "error": {
    ///     "code": 403,
    ///     "message": "Permission 'aiplatform.endpoints.predict' denied on resource ...",
    ///     "status": "PERMISSION_DENIED",
    ///     "details": [
    ///       { "@type": "type.googleapis.com/google.rpc.ErrorInfo",
    ///         "reason": "IAM_PERMISSION_DENIED",
    ///         "domain": "aiplatform.googleapis.com",
    ///         "metadata": { "permission": "aiplatform.endpoints.predict", ... }
    ///       }
    ///     ]
    ///   }
    /// }
    /// ```
    private static func parseGoogleErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else {
            return nil
        }

        var parts: [String] = []

        // Main message
        if let message = error["message"] as? String {
            parts.append(message)
        }

        // Status code name (e.g., "PERMISSION_DENIED")
        if let status = error["status"] as? String, !status.isEmpty {
            parts.append("Status: \(status)")
        }

        // Dig into details for specific IAM info
        if let details = error["details"] as? [[String: Any]] {
            for detail in details {
                if let reason = detail["reason"] as? String {
                    parts.append("Reason: \(reason)")
                }
                if let metadata = detail["metadata"] as? [String: String] {
                    if let permission = metadata["permission"] {
                        parts.append("Missing permission: \(permission)")
                    }
                    if let resource = metadata["resource"] {
                        parts.append("Resource: \(resource)")
                    }
                }
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
