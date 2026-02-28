import Foundation
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "GeminiClient")

// MARK: - Transcription Provider Protocol

/// Protocol defining the interface for transcription providers.
/// This allows swapping between Gemini Direct (v1) and Vertex AI (v2).
protocol TranscriptionProvider: Sendable {
    func transcribe(audio: Data, context: String?, dictionary: [String]) async throws -> String
    func processCommand(selectedText: String, command: String) async throws -> String
}

// MARK: - Gemini Errors

enum GeminiError: Error, LocalizedError {
    case invalidAPIKey
    case networkError(Error)
    case invalidResponse
    case apiError(String)
    case audioTooLong
    case noTextInResponse
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            return "Invalid or missing API key"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .apiError(let message):
            return "API error: \(message)"
        case .audioTooLong:
            return "Audio recording exceeds maximum length"
        case .noTextInResponse:
            return "No text returned from API"
        case .requestTooLarge:
            return "Audio file too large (max 20MB)"
        }
    }
}

// MARK: - Gemini Client

/// Client for the Google Gemini Direct API (v1).
/// Sends audio data with a system prompt and returns cleaned, formatted text.
struct GeminiClient: TranscriptionProvider {

    private let apiKey: String
    private let model: String
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta"

    init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - Transcription

    func transcribe(
        audio: Data,
        context: String? = nil,
        dictionary: [String] = []
    ) async throws -> String {

        // Validate audio size (max 20MB for inline data)
        guard audio.count < 20 * 1024 * 1024 else {
            throw GeminiError.requestTooLarge
        }

        let base64Audio = audio.base64EncodedString()

        let systemPrompt = buildDictationPrompt(
            context: context,
            dictionary: dictionary
        )

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

    // MARK: - Command Mode

    func processCommand(
        selectedText: String,
        command: String
    ) async throws -> String {

        let systemPrompt = buildCommandPrompt()

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

    private func sendRequest(_ request: GeminiRequest) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GeminiError.invalidAPIKey
        }

        let urlString = "\(baseURL)/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GeminiError.invalidResponse
        }

        logger.info("Gemini API request → \(urlString)")
        print("[Bolo] Gemini API request → \(urlString)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.timeoutInterval = 60  // Increased from 30s for large audio
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let bodySize = urlRequest.httpBody?.count ?? 0
        logger.info("Request body size: \(bodySize) bytes")
        print("[Bolo] Request body size: \(bodySize) bytes")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            print("[Bolo] Network error: \(error)")
            throw GeminiError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        logger.info("Gemini API response — HTTP \(httpResponse.statusCode), body: \(data.count) bytes")
        print("[Bolo] Gemini API response — HTTP \(httpResponse.statusCode), body: \(data.count) bytes")

        // Handle HTTP errors
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            print("[Bolo] API key rejected (HTTP \(httpResponse.statusCode))")
            throw GeminiError.invalidAPIKey
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("API error: HTTP \(httpResponse.statusCode) — \(errorBody.prefix(500))")
            print("[Bolo] API error: HTTP \(httpResponse.statusCode) — \(errorBody.prefix(500))")
            throw GeminiError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
        }

        // Log raw response for debugging
        if let responseStr = String(data: data, encoding: .utf8) {
            print("[Bolo] Gemini raw response: \(responseStr.prefix(300))")
        }

        let geminiResponse: GeminiResponse
        do {
            geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            logger.error("JSON decode failed: \(error.localizedDescription)")
            print("[Bolo] JSON decode failed: \(error)")
            throw GeminiError.invalidResponse
        }

        guard let text = geminiResponse.candidates?.first?.content?.parts?.first?.text else {
            logger.error("No text in response — candidates: \(geminiResponse.candidates?.count ?? 0)")
            print("[Bolo] No text in Gemini response")
            throw GeminiError.noTextInResponse
        }

        logger.info("Gemini returned: \(text.prefix(100))")
        print("[Bolo] Gemini returned: \(text.prefix(100))")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: Prompt Building

    private func buildDictationPrompt(context: String?, dictionary: [String]) -> String {
        var prompt = """
        You are a dictation assistant. Your job is to transcribe speech into clean, polished text.

        RULES:
        1. Remove filler words: um, uh, like, you know, basically, actually, so, well, right, okay
        2. Add proper punctuation based on speech patterns and pauses
        3. Fix grammar: subject-verb agreement, tense consistency, sentence structure
        4. Handle course corrections: when user says "no wait", "I mean", "actually", \
        "scratch that", "let me rephrase" — output only the corrected version
        5. Never include the correction phrases themselves in output
        6. Maintain the speaker's intended meaning and tone
        7. Output ONLY the transcribed text, no explanations or commentary
        8. Do not wrap output in quotes or markdown
        """

        if let ctx = context, !ctx.isEmpty {
            prompt += "\n\nCONTEXT (surrounding text for formatting guidance):\n\(ctx)"
        }

        if !dictionary.isEmpty {
            prompt += "\n\nPERSONAL DICTIONARY (use these exact spellings):\n"
            prompt += dictionary.joined(separator: ", ")
        }

        return prompt
    }

    private func buildCommandPrompt() -> String {
        return """
        You are a text editing assistant. The user will provide selected text and a voice command.

        Apply the command to transform the text. Common commands:
        - "make this more formal" → Rewrite in professional tone
        - "make this casual" → Rewrite in friendly tone
        - "summarize" or "summarize this" → Create concise summary
        - "fix grammar" or "fix the grammar" → Correct grammatical errors
        - "make shorter" or "make it shorter" → Condense while preserving meaning
        - "bullet points" or "turn into bullet points" → Convert to bulleted list
        - "expand" or "expand on this" → Add more detail
        - "translate to [language]" → Translate to specified language
        - "rewrite this" → Rewrite while keeping the same meaning

        Output ONLY the transformed text. No explanations, no markdown formatting \
        unless specifically requested.
        """
    }
}

// MARK: - Request/Response Models

struct GeminiRequest: Codable {
    let contents: [Content]
    let systemInstruction: Content?
    let generationConfig: GenerationConfig?
}

struct Content: Codable {
    let parts: [Part]
    let role: String?

    init(parts: [Part], role: String? = nil) {
        self.parts = parts
        self.role = role
    }
}

struct Part: Codable {
    let text: String?
    let inlineData: InlineData?

    init(text: String) {
        self.text = text
        self.inlineData = nil
    }

    init(inlineData: InlineData) {
        self.text = nil
        self.inlineData = inlineData
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }
}

struct InlineData: Codable {
    let mimeType: String
    let data: String

    enum CodingKeys: String, CodingKey {
        case mimeType = "mime_type"
        case data
    }
}

struct GenerationConfig: Codable {
    let temperature: Float?
    let maxOutputTokens: Int?
}

struct GeminiResponse: Codable {
    let candidates: [Candidate]?
}

struct Candidate: Codable {
    let content: ResponseContent?
    let finishReason: String?
}

struct ResponseContent: Codable {
    let parts: [ResponsePart]?
}

struct ResponsePart: Codable {
    let text: String?
}
