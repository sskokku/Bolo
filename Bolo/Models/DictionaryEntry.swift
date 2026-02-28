import Foundation

/// A personal dictionary entry for custom words, names, acronyms, and jargon.
/// Stored in a local SQLite database and included in Gemini API prompts
/// so the model uses the correct spelling.
struct DictionaryEntry: Identifiable, Codable, Equatable {
    var id: String
    var term: String
    var pronunciation: String?
    var category: String
    var frequency: Int
    var dateAdded: Date
    var dateLastUsed: Date
    var isAutoLearned: Bool

    /// Create a new entry with sensible defaults.
    init(
        term: String,
        pronunciation: String? = nil,
        category: String = "custom"
    ) {
        self.id = UUID().uuidString
        self.term = term
        self.pronunciation = pronunciation
        self.category = category
        self.frequency = 0
        self.dateAdded = Date()
        self.dateLastUsed = Date()
        self.isAutoLearned = false
    }

    /// Full initializer for restoring from database.
    init(
        id: String,
        term: String,
        pronunciation: String?,
        category: String,
        frequency: Int,
        dateAdded: Date,
        dateLastUsed: Date,
        isAutoLearned: Bool
    ) {
        self.id = id
        self.term = term
        self.pronunciation = pronunciation
        self.category = category
        self.frequency = frequency
        self.dateAdded = dateAdded
        self.dateLastUsed = dateLastUsed
        self.isAutoLearned = isAutoLearned
    }
}

/// Predefined categories for dictionary entries.
enum DictionaryCategory: String, CaseIterable {
    case name = "name"
    case acronym = "acronym"
    case technical = "technical"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .acronym: return "Acronym"
        case .technical: return "Technical"
        case .custom: return "Custom"
        }
    }
}
