import Foundation

// MARK: - Recording State

/// Represents the current state of the application's recording pipeline.
enum RecordingState: Equatable {
    case idle
    case recording(mode: RecordingMode)
    case processing
    case inserting
    case error(AppError)
}

// MARK: - Recording Mode

/// The mode of the current recording session.
enum RecordingMode: Equatable {
    /// Hold-to-record: starts on key press, stops on release
    case pushToTalk
    /// Toggle-based: press to start, press again to stop
    case longTalk
    /// Voice command to transform selected text
    case command
}

// MARK: - App Error

/// Application-level errors with user-friendly messages and recovery actions.
enum AppError: Error, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case apiKeyMissing
    case apiError(String)
    case networkError
    case audioTooShort
    case audioTooLong
    case insertionFailed
    case noFocusedTextField
    case protectedField
}

// MARK: - App State

/// Observable application state shared across the UI.
/// This is platform-agnostic and can be used on any platform with SwiftUI.
@MainActor
class AppState: ObservableObject {

    @Published var state: RecordingState = .idle
    @Published var audioLevel: Float = 0
    @Published var recordingDuration: TimeInterval = 0
    @Published var isLongTalkActive: Bool = false

    // MARK: - Computed Properties

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = state { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    var currentMode: RecordingMode? {
        if case .recording(let mode) = state { return mode }
        return nil
    }

    var statusText: String {
        switch state {
        case .idle:
            return isLongTalkActive ? "Long-Talk Active" : "Ready"
        case .recording(let mode):
            let modeText: String
            switch mode {
            case .pushToTalk: modeText = "Recording"
            case .longTalk: modeText = "Long-Talk"
            case .command: modeText = "Command"
            }
            return "\(modeText): \(formatDuration(recordingDuration))"
        case .processing:
            return "Processing..."
        case .inserting:
            return "Inserting..."
        case .error(let error):
            return errorMessage(for: error)
        }
    }

    // MARK: - Private

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func errorMessage(for error: AppError) -> String {
        switch error {
        case .microphonePermissionDenied:
            return "Microphone access required"
        case .accessibilityPermissionDenied:
            return "Accessibility access required"
        case .apiKeyMissing:
            return "API key not configured"
        case .apiError(let message):
            return "API Error: \(message)"
        case .networkError:
            return "Network error"
        case .audioTooShort:
            return "Recording too short"
        case .audioTooLong:
            return "Recording too long (max 5 min)"
        case .insertionFailed:
            return "Failed to insert text"
        case .noFocusedTextField:
            return "No text field focused"
        case .protectedField:
            return "Cannot dictate into password fields"
        }
    }
}
