//
//  AppleSpeechProvider.swift
//  Bolo
//
//  On-device speech-to-text via the macOS 26 SpeechAnalyzer / SpeechTranscriber API.
//  No network, no LLM. Audio in, words out.
//

import Foundation
import AVFoundation
import Speech

@available(macOS 26, *)
struct AppleSpeechProvider: TranscriptionProvider {
    var displayName: String { "Apple Speech (on-device)" }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriptionError.unsupported("Apple Speech does not support the current locale (\(Locale.current.identifier)).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssetsInstalled(for: transcriber)

        // SpeechAnalyzer reads from an AVAudioFile, so persist the captured bytes to a temp file.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bolo-apple-\(UUID().uuidString).wav")
        try request.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task<String, Error> {
            var combined = ""
            for try await result in transcriber.results {
                combined += String(result.text.characters)
            }
            return combined.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            collector.cancel()
            throw error
        }

        let text = try await collector.value
        guard !text.isEmpty else { throw TranscriptionError.empty }
        return TranscriptionResult(text: text, modelUsed: "SpeechTranscriber (\(locale.identifier))")
    }

    func testConnection() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw TranscriptionError.unsupported("Apple Speech does not support the current locale (\(Locale.current.identifier)).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssetsInstalled(for: transcriber)
    }

    private func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        if let installRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installRequest.downloadAndInstall()
        }
    }
}
