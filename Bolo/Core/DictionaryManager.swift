import Foundation
import SQLite3

/// Manages the personal dictionary stored in a local SQLite database.
/// Supports CRUD operations, auto-learning, and provides top entries
/// for inclusion in Gemini API prompts.
class DictionaryManager {

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

        dbPath = boloDir.appendingPathComponent("dictionary.sqlite").path
        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public API

    /// Add or update a dictionary entry.
    func addEntry(_ entry: DictionaryEntry) {
        let sql = """
        INSERT OR REPLACE INTO dictionary
        (id, term, pronunciation, category, frequency, date_added, date_last_used, is_auto_learned)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, entry.id)
        bindText(statement, 2, entry.term)
        bindOptionalText(statement, 3, entry.pronunciation)
        bindText(statement, 4, entry.category)
        sqlite3_bind_int(statement, 5, Int32(entry.frequency))
        sqlite3_bind_double(statement, 6, entry.dateAdded.timeIntervalSince1970)
        sqlite3_bind_double(statement, 7, entry.dateLastUsed.timeIntervalSince1970)
        sqlite3_bind_int(statement, 8, entry.isAutoLearned ? 1 : 0)

        sqlite3_step(statement)
    }

    /// Retrieve all dictionary entries, sorted by frequency then last used.
    func getAllEntries() -> [DictionaryEntry] {
        let sql = "SELECT * FROM dictionary ORDER BY frequency DESC, date_last_used DESC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var entries: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseRow(statement) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Get the top N most-used terms for inclusion in Gemini prompts.
    func getTopEntries(limit: Int = 50) -> [String] {
        let sql = "SELECT term FROM dictionary ORDER BY frequency DESC, date_last_used DESC LIMIT ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var terms: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let term = sqlite3_column_text(statement, 0) {
                terms.append(String(cString: term))
            }
        }

        return terms
    }

    /// Increment the usage frequency for a term.
    func incrementUsage(term: String) {
        let sql = """
        UPDATE dictionary
        SET frequency = frequency + 1, date_last_used = ?
        WHERE term = ? COLLATE NOCASE
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        bindText(statement, 2, term)

        sqlite3_step(statement)
    }

    /// Delete a dictionary entry by ID.
    func deleteEntry(id: String) {
        let sql = "DELETE FROM dictionary WHERE id = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, id)
        sqlite3_step(statement)
    }

    /// Search entries by term.
    func searchEntries(query: String) -> [DictionaryEntry] {
        let sql = "SELECT * FROM dictionary WHERE term LIKE ? ORDER BY frequency DESC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, "%\(query)%")

        var entries: [DictionaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = parseRow(statement) {
                entries.append(entry)
            }
        }

        return entries
    }

    /// Get the total number of entries.
    var entryCount: Int {
        let sql = "SELECT COUNT(*) FROM dictionary"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    // MARK: - Import/Export

    /// Export all entries as JSON data.
    func exportToJSON() -> Data? {
        let entries = getAllEntries()
        return try? JSONEncoder().encode(entries)
    }

    /// Import entries from JSON data.
    func importFromJSON(_ data: Data) -> Int {
        guard let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            return 0
        }

        var count = 0
        for entry in entries {
            addEntry(entry)
            count += 1
        }
        return count
    }

    // MARK: - Private: Database

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[Bolo] Error opening dictionary database at \(dbPath)")
        }
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS dictionary (
            id TEXT PRIMARY KEY,
            term TEXT NOT NULL,
            pronunciation TEXT,
            category TEXT NOT NULL DEFAULT 'custom',
            frequency INTEGER NOT NULL DEFAULT 0,
            date_added REAL NOT NULL,
            date_last_used REAL NOT NULL,
            is_auto_learned INTEGER NOT NULL DEFAULT 0,
            UNIQUE(term COLLATE NOCASE)
        );
        CREATE INDEX IF NOT EXISTS idx_dictionary_term ON dictionary(term);
        CREATE INDEX IF NOT EXISTS idx_dictionary_frequency ON dictionary(frequency DESC);
        """

        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func parseRow(_ statement: OpaquePointer?) -> DictionaryEntry? {
        guard let idPtr = sqlite3_column_text(statement, 0),
              let termPtr = sqlite3_column_text(statement, 1),
              let categoryPtr = sqlite3_column_text(statement, 3) else {
            return nil
        }

        let pronunciation: String? = sqlite3_column_text(statement, 2).map { String(cString: $0) }

        var entry = DictionaryEntry(
            term: String(cString: termPtr),
            pronunciation: pronunciation,
            category: String(cString: categoryPtr)
        )
        // Restore the original ID from the database
        entry = DictionaryEntry(
            id: String(cString: idPtr),
            term: entry.term,
            pronunciation: pronunciation,
            category: entry.category,
            frequency: Int(sqlite3_column_int(statement, 4)),
            dateAdded: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            dateLastUsed: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isAutoLearned: sqlite3_column_int(statement, 7) == 1
        )

        return entry
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
