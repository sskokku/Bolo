import Foundation
import AppKit
import os.log

// MARK: - Log Severity

/// Severity levels for structured log entries.
enum LogSeverity: String, Codable {
    case info
    case warning
    case error
}

// MARK: - Log Category

/// Categories for grouping log entries by subsystem.
enum LogCategory: String, Codable {
    case audio
    case api
    case insertion
    case hotkey
    case settings
    case app
    case dictionary
    case history
}

// MARK: - Log Entry

/// A single structured log entry, serialized as a JSON line.
struct LogEntry: Codable {
    let timestamp: Date
    let severity: LogSeverity
    let category: LogCategory
    let message: String
    var appState: String? = nil
    var details: String? = nil

    /// Encode to a single JSON line (no pretty printing).
    func toJSONLine() -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Error Logger

/// Singleton structured logger that writes JSON-line entries to a local log file.
///
/// **Guardrails:**
/// - Daily auto-purge at 11:59 PM local time (configurable via timer)
/// - User-selectable max file size; if exceeded within the day, the user is
///   notified and the file is purged
/// - File location: `~/Library/Logs/Bolo/bolo.log`
///
/// Thread-safe: all file I/O is serialized on a dedicated dispatch queue.
final class ErrorLogger: @unchecked Sendable {

    static let shared = ErrorLogger()

    // MARK: - Constants

    private let logDirectory: URL = {
        // Use Application Support container — compatible with App Sandbox.
        // ~/Library/Logs/ is outside the sandbox; ~/Library/Application Support/{BundleID}/Logs/ is not.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Bolo", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        return appSupport
    }()

    private var logFileURL: URL {
        logDirectory.appendingPathComponent("bolo.log")
    }

    // MARK: - State

    private let queue = DispatchQueue(label: "com.bolo.errorlogger", qos: .utility)
    private var fileHandle: FileHandle?
    private var dailyPurgeTimer: Timer?
    private var currentFileSize: UInt64 = 0
    private var hasSentSizeWarningToday = false

    /// The system logger — we still log to os.log in parallel.
    private let logger = Logger(subsystem: "com.bolo.app", category: "ErrorLogger")

    // MARK: - Init

    private init() {
        ensureLogDirectory()
        currentFileSize = calculateFileSize()
        scheduleDailyPurge()
        // Log app launch
        log(.info, category: .app, message: "Bolo launched — ErrorLogger initialized")
    }

    deinit {
        dailyPurgeTimer?.invalidate()
        queue.sync {
            fileHandle?.closeFile()
        }
    }

    // MARK: - Public API

    /// Write a structured log entry.
    func log(
        _ severity: LogSeverity,
        category: LogCategory,
        message: String,
        appState: String? = nil,
        details: String? = nil
    ) {
        let entry = LogEntry(
            timestamp: Date(),
            severity: severity,
            category: category,
            message: message,
            appState: appState,
            details: details
        )

        queue.async { [weak self] in
            self?.writeEntry(entry)
        }

        // Mirror to os.log
        switch severity {
        case .info:
            logger.info("\(category.rawValue): \(message)")
        case .warning:
            logger.warning("\(category.rawValue): \(message)")
        case .error:
            logger.error("\(category.rawValue): \(message)")
        }
    }

    /// Convenience for logging errors with automatic detail extraction.
    func logError(
        category: LogCategory,
        message: String,
        error: Error? = nil,
        appState: String? = nil
    ) {
        log(
            .error,
            category: category,
            message: message,
            appState: appState,
            details: error?.localizedDescription
        )
    }

    /// Convenience for logging warnings.
    func logWarning(
        category: LogCategory,
        message: String,
        appState: String? = nil
    ) {
        log(.warning, category: category, message: message, appState: appState)
    }

    /// Convenience for logging info.
    func logInfo(
        category: LogCategory,
        message: String,
        appState: String? = nil
    ) {
        log(.info, category: category, message: message, appState: appState)
    }

    /// Manually purge the log file. Called by the daily timer and the size guard.
    func purgeLogFile() {
        queue.async { [weak self] in
            self?.performPurge()
        }
    }

    /// Returns the current log file size in bytes.
    func getLogFileSize() -> UInt64 {
        return queue.sync { currentFileSize }
    }

    /// Returns the log file URL for opening in Finder / Console.
    func getLogFileURL() -> URL {
        return logFileURL
    }

    /// Read all log entries (for a "View Logs" UI).
    func readEntries() -> [LogEntry] {
        return queue.sync {
            guard let data = try? Data(contentsOf: logFileURL) else { return [] }
            let lines = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines) ?? []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return lines.compactMap { line in
                guard !line.isEmpty, let lineData = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(LogEntry.self, from: lineData)
            }
        }
    }

    // MARK: - File I/O

    private func ensureLogDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDirectory.path) {
            try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private func writeEntry(_ entry: LogEntry) {
        guard var line = entry.toJSONLine() else { return }
        line += "\n"

        guard let data = line.data(using: .utf8) else { return }

        // Check size limit before writing
        let maxSize = maxLogFileSizeBytes()
        if currentFileSize + UInt64(data.count) > maxSize {
            handleSizeLimitExceeded()
            return
        }

        // Append to file
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
            currentFileSize += UInt64(data.count)
        }
    }

    private func performPurge() {
        let fm = FileManager.default
        if fm.fileExists(atPath: logFileURL.path) {
            try? fm.removeItem(at: logFileURL)
        }
        currentFileSize = 0
        hasSentSizeWarningToday = false

        // Write a fresh first entry
        let entry = LogEntry(
            timestamp: Date(),
            severity: .info,
            category: .app,
            message: "Log file purged"
        )
        writeEntry(entry)
    }

    private func calculateFileSize() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attrs[.size] as? UInt64 else {
            return 0
        }
        return size
    }

    // MARK: - Size Guard

    private func maxLogFileSizeBytes() -> UInt64 {
        // Read from UserDefaults (set by SettingsModel)
        let mb = UserDefaults.standard.integer(forKey: SettingsKey.maxLogFileSize)
        let effectiveMB = mb > 0 ? mb : 5 // default 5 MB
        return UInt64(effectiveMB) * 1_048_576 // MB → bytes
    }

    private func handleSizeLimitExceeded() {
        guard !hasSentSizeWarningToday else { return }
        hasSentSizeWarningToday = true

        let sizeMB = String(format: "%.1f", Double(currentFileSize) / 1_048_576.0)
        let maxMB = maxLogFileSizeBytes() / 1_048_576
        logger.warning("Log file size (\(sizeMB) MB) exceeded limit (\(maxMB) MB) — purging and notifying user")

        // Purge the file
        performPurge()

        // Notify user on main thread
        DispatchQueue.main.async {
            self.showSizeLimitAlert(sizeMB: sizeMB, maxMB: maxMB)
        }
    }

    @MainActor
    private func showSizeLimitAlert(sizeMB: String, maxMB: UInt64) {
        let alert = NSAlert()
        alert.messageText = "Log File Purged"
        alert.informativeText = """
        Bolo's log file reached \(sizeMB) MB (limit: \(maxMB) MB) and has been automatically purged to save disk space.

        This usually means something is generating a lot of log entries. \
        You can adjust the max log file size in Settings → Logging.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Post notification to open settings
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Daily Purge Timer

    /// Schedule a timer that fires at 11:59 PM local time every day.
    private func scheduleDailyPurge() {
        // Cancel existing timer
        dailyPurgeTimer?.invalidate()

        guard let nextPurgeDate = nextPurgeTime() else {
            logger.error("Failed to calculate next purge time")
            return
        }

        let interval = nextPurgeDate.timeIntervalSinceNow
        logger.info("Next log purge scheduled at \(nextPurgeDate) (in \(Int(interval))s)")

        // Use a one-shot timer, then reschedule
        DispatchQueue.main.async { [weak self] in
            self?.dailyPurgeTimer = Timer.scheduledTimer(
                withTimeInterval: max(interval, 1),
                repeats: false
            ) { [weak self] _ in
                guard let self else { return }
                self.logger.info("Daily log purge triggered at 11:59 PM")
                self.purgeLogFile()
                // Reschedule for the next day
                self.scheduleDailyPurge()
            }
        }
    }

    /// Calculate the next 11:59 PM in the user's local timezone.
    private func nextPurgeTime() -> Date? {
        let calendar = Calendar.current
        let now = Date()

        // Today at 23:59:00
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 23
        components.minute = 59
        components.second = 0

        guard let todayPurge = calendar.date(from: components) else { return nil }

        // If 11:59 PM hasn't passed yet today, use it; otherwise schedule for tomorrow
        if todayPurge > now {
            return todayPurge
        } else {
            return calendar.date(byAdding: .day, value: 1, to: todayPurge)
        }
    }
}
