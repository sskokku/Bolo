//
//  AudioRecorder.swift
//  Bolo
//
//  AVAudioEngine-based recorder. Engine + mic tap only run while actively
//  recording so macOS doesn't show the system mic indicator at idle.
//

import AVFoundation
import AppKit

final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var isWriting = false
    private var permissionRequested = false

    enum RecorderError: LocalizedError {
        case permissionDenied
        case engineFailure(String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission denied. Open System Settings → Privacy & Security → Microphone and enable Bolo."
            case .engineFailure(let msg):
                return "Audio engine error: \(msg)"
            case .noAudio:
                return "No audio captured."
            }
        }
    }

    /// Triggers the mic permission prompt at app launch without holding the mic open.
    func prewarm() async {
        guard !permissionRequested else { return }
        permissionRequested = true
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            break
        }
    }

    func start() async throws {
        try await ensureMicAuthorized()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.writeBufferIfRecording(buffer)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bolo-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.lock()
        audioFile = file
        fileURL = url
        isWriting = true
        lock.unlock()

        do {
            try engine.start()
        } catch {
            lock.lock()
            isWriting = false
            audioFile = nil
            fileURL = nil
            lock.unlock()
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailure(error.localizedDescription)
        }
    }

    func stop() throws -> (data: Data, mimeType: String) {
        lock.lock()
        isWriting = false
        audioFile = nil
        let url = fileURL
        fileURL = nil
        lock.unlock()

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        guard let url else { throw RecorderError.noAudio }
        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        guard !data.isEmpty else { throw RecorderError.noAudio }
        return (data, "audio/wav")
    }

    private func ensureMicAuthorized() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            await MainActor.run {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw RecorderError.permissionDenied }
        case .denied, .restricted:
            throw RecorderError.permissionDenied
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    private func writeBufferIfRecording(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writing = isWriting
        let file = audioFile
        lock.unlock()
        guard writing, let file else { return }
        try? file.write(from: buffer)
    }
}
