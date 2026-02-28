import Foundation

/// The result of a transcription or command processing request.
struct TranscriptionResult {
    let text: String
    let mode: RecordingMode
    let duration: TimeInterval
    let timestamp: Date
    let appContext: String?

    init(
        text: String,
        mode: RecordingMode,
        duration: TimeInterval,
        appContext: String? = nil
    ) {
        self.text = text
        self.mode = mode
        self.duration = duration
        self.timestamp = Date()
        self.appContext = appContext
    }

    /// Convert to a HistoryEntry for persistence.
    func toHistoryEntry() -> HistoryEntry {
        HistoryEntry(
            text: text,
            mode: mode,
            appName: appContext,
            duration: duration
        )
    }
}
