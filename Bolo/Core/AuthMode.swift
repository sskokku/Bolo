import Foundation

/// Which authentication backend is active.
enum AuthMode: String, CaseIterable, Identifiable {
    case geminiDirect = "gemini_direct"   // API key via x-goog-api-key
    case vertexAI     = "vertex_ai"       // OAuth2 Bearer token via Vertex AI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geminiDirect: return "Gemini API Key"
        case .vertexAI:     return "Vertex AI (Google Sign-In)"
        }
    }
}
