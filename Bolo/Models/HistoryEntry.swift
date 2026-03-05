import Foundation

/// A record of a past transcription, stored in the local history database.
struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: String
    let text: String
    let mode: String
    let appName: String?
    let timestamp: Date
    let duration: TimeInterval
    let wordCount: Int

    /// Create a new history entry.
    init(
        text: String,
        mode: RecordingMode,
        appName: String? = nil,
        duration: TimeInterval = 0
    ) {
        self.id = UUID().uuidString
        self.text = text
        self.mode = mode.displayName
        self.appName = appName
        self.timestamp = Date()
        self.duration = duration
        self.wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Full initializer for restoring from database.
    init(
        id: String,
        text: String,
        mode: String,
        appName: String?,
        timestamp: Date,
        duration: TimeInterval,
        wordCount: Int
    ) {
        self.id = id
        self.text = text
        self.mode = mode
        self.appName = appName
        self.timestamp = timestamp
        self.duration = duration
        self.wordCount = wordCount
    }
}

// MARK: - RecordingMode Extension

extension RecordingMode {
    var displayName: String {
        switch self {
        case .pushToTalk: return "Push-to-Talk"
        case .longTalk: return "Long-Talk"
        case .command: return "Command"
        }
    }
}
