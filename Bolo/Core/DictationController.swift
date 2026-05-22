//
//  DictationController.swift
//  Bolo
//

import Foundation
import Observation
import AppKit
import ApplicationServices
import SwiftData

@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case result(String)
        case failure(String)
    }

    var state: State = .idle
    var lastTranscript: String = ""

    let modelContainer: ModelContainer

    private let recorder = AudioRecorder()
    private var preDictationApp: NSRunningApplication?
    private var pttStartTime: Date?
    private var modelContext: ModelContext { modelContainer.mainContext }

    private let accidentalTapThreshold: TimeInterval = 0.25
    private let providerKind = "appleSpeech"

    private init() {
        let schema = Schema([Transcription.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData ModelContainer init failed: \(error)")
        }
        Task { await recorder.prewarm() }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isBusy: Bool {
        switch state {
        case .recording, .transcribing: return true
        default: return false
        }
    }

    // MARK: Manual toggle (popover button / Space)

    func toggle() async {
        switch state {
        case .idle, .result, .failure:
            await start()
        case .recording:
            await finish()
        case .transcribing:
            break
        }
    }

    // MARK: Push-to-talk (⌃⇧ hold)

    func pttPress() async {
        guard !isBusy else { return }
        pttStartTime = Date()
        await start()
    }

    func pttRelease() async {
        guard isRecording else {
            pttStartTime = nil
            return
        }
        let elapsed = pttStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pttStartTime = nil
        if elapsed < accidentalTapThreshold {
            _ = try? recorder.stop()
            state = .idle
            return
        }
        await finish()
    }

    // MARK: Core flow

    func start() async {
        preDictationApp = NSWorkspace.shared.frontmostApplication
        do {
            try await recorder.start()
            state = .recording
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func finish() async {
        let captured: (data: Data, mimeType: String)
        do {
            captured = try recorder.stop()
        } catch {
            state = .failure(error.localizedDescription)
            return
        }
        state = .transcribing
        let provider: any TranscriptionProvider
        if #available(macOS 26, *) {
            provider = AppleSpeechProvider()
        } else {
            state = .failure("Apple Speech requires macOS 26 or later.")
            return
        }
        let req = TranscriptionRequest(audio: captured.data, mimeType: captured.mimeType)
        do {
            let res = try await provider.transcribe(req)
            lastTranscript = res.text
            copyToClipboard()
            await autoPasteIfPossible(text: res.text)
            saveToHistory(text: res.text, model: res.modelUsed)
            state = .result(res.text)
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func copyToClipboard() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    func reset() {
        state = .idle
        lastTranscript = ""
    }

    private func saveToHistory(text: String, model: String) {
        let record = Transcription(text: text, providerKind: providerKind, model: model)
        modelContext.insert(record)
        try? modelContext.save()
        UsageStats.shared.record(wordCount: record.wordCount)
    }

    private func autoPasteIfPossible(text: String) async {
        guard AXIsProcessTrusted() else { return }
        let target = preDictationApp ?? NSWorkspace.shared.frontmostApplication
        if let target, target.bundleIdentifier != Bundle.main.bundleIdentifier {
            // Explicitly grant Bolo's activation rights to the target so macOS 14+
            // permits the focus switch even if the user clicked elsewhere mid-transcription.
            _ = target.activate(from: .current, options: [.activateAllWindows])
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        TextInjector.pasteText(text)
    }
}
