import Foundation
import SQLite3
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "HistoryManager")

/// Manages transcription history stored in a local SQLite database.
/// Keeps a record of recent transcriptions for review and re-use.
class HistoryManager {

    private var db: OpaquePointer?
    private let dbPath: String

    init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let boloDir = appSupport.appendingPathComponent("Bolo")

        try? fileManager.createDirectory(at: boloDir, withIntermediateDirectories: true)

        dbPath = boloDir.appendingPathComponent("history.sqlite").path
        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Add a transcription to the history.
    func addEntry(_ entry: HistoryEntry) {
        let sql = """
        INSERT INTO history (id, text, mode, app_name, timestamp, duration)
        VALUES (?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, entry.id)
        bindText(statement, 2, entry.text)
        bindText(statement, 3, entry.mode)
        bindOptionalText(statement, 4, entry.appName)
        sqlite3_bind_double(statement, 5, entry.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, entry.duration)

        sqlite3_step(statement)
    }

    /// Get recent history entries, newest first.
    func getRecentEntries(limit: Int = 50) -> [HistoryEntry] {
        let sql = "SELECT * FROM history ORDER BY timestamp DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseRow(statement) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Search history entries by text content.
    func searchEntries(query: String) -> [HistoryEntry] {
        let sql = "SELECT * FROM history WHERE text LIKE ? ORDER BY timestamp DESC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, "%\(query)%")

        var entries: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseRow(statement) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Delete a specific history entry.
    func deleteEntry(id: String) {
        let sql = "DELETE FROM history WHERE id = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, id)
        sqlite3_step(statement)
    }

    /// Clear all history entries.
    func clearAll() {
        sqlite3_exec(db, "DELETE FROM history", nil, nil, nil)
    }

    /// Clean up entries older than the specified number of days.
    func cleanupOldEntries(olderThanDays: Int = 30) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(olderThanDays * 86400))
        let sql = "DELETE FROM history WHERE timestamp < ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        sqlite3_step(statement)
    }

    // MARK: - Private: Database

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            logger.error("Failed to open history database at \(self.dbPath)")
            ErrorLogger.shared.logError(category: .history, message: "Failed to open history database at \(self.dbPath)")
        }
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            mode TEXT NOT NULL,
            app_name TEXT,
            timestamp REAL NOT NULL,
            duration REAL NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
        """

        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func parseRow(_ statement: OpaquePointer?) -> HistoryEntry? {
        guard let idPtr = sqlite3_column_text(statement, 0),
              let textPtr = sqlite3_column_text(statement, 1),
              let modePtr = sqlite3_column_text(statement, 2) else {
            return nil
        }

        let appName: String? = sqlite3_column_text(statement, 3).map { String(cString: $0) }

        return HistoryEntry(
            id: String(cString: idPtr),
            text: String(cString: textPtr),
            mode: String(cString: modePtr),
            appName: appName,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            duration: sqlite3_column_double(statement, 5)
        )
    }

    // MARK: - Private: Bind Helpers

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let nsString = value as NSString
        sqlite3_bind_text(statement, index, nsString.utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let val = value {
            bindText(statement, index, val)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}
