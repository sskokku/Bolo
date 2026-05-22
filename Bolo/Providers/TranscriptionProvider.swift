//
//  TranscriptionProvider.swift
//  Bolo
//

import Foundation

struct TranscriptionRequest {
    let audio: Data
    let mimeType: String
}

struct TranscriptionResult {
    let text: String
    let modelUsed: String
}

protocol TranscriptionProvider: Sendable {
    var displayName: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
    func testConnection() async throws
}

enum TranscriptionError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case empty
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let snippet = body.prefix(200)
            return "HTTP \(code): \(snippet)"
        case .decoding(let msg): return "Decoding error: \(msg)"
        case .empty: return "Empty response from provider"
        case .unsupported(let msg): return msg
        }
    }
}
