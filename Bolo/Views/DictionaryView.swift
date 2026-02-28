import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "DictionaryView")

/// Dictionary management view for adding, editing, and removing personal dictionary entries.
struct DictionaryView: View {

    @State private var entries: [DictionaryEntry] = []
    @State private var searchText = ""
    @State private var newTerm = ""
    @State private var newCategory = "custom"
    @State private var showingAddSheet = false

    private let dictionaryManager = DictionaryManager()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search dictionary...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _, newValue in
                        refreshEntries(query: newValue)
                    }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            // Entry list
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No dictionary entries")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add custom words, names, and acronyms\nfor better transcription accuracy.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        DictionaryEntryRow(entry: entry)
                    }
                    .onDelete(perform: deleteEntries)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("\(entries.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Import...") { importDictionary() }
                    .font(.caption)
                Button("Export...") { exportDictionary() }
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 500, height: 400)
        .onAppear { refreshEntries() }
        .sheet(isPresented: $showingAddSheet) {
            AddDictionaryEntrySheet(
                onSave: { term, category in
                    let entry = DictionaryEntry(term: term, category: category)
                    dictionaryManager.addEntry(entry)
                    refreshEntries()
                }
            )
        }
    }

    // MARK: - Data Operations

    private func refreshEntries(query: String = "") {
        if query.isEmpty {
            entries = dictionaryManager.getAllEntries()
        } else {
            entries = dictionaryManager.searchEntries(query: query)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            dictionaryManager.deleteEntry(id: entries[index].id)
        }
        refreshEntries(query: searchText)
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url) {
                let count = dictionaryManager.importFromJSON(data)
                refreshEntries()
                logger.info("Imported \(count) dictionary entries")
                ErrorLogger.shared.logInfo(category: .dictionary, message: "Imported \(count) dictionary entries")
            }
        }
    }

    private func exportDictionary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "bolo-dictionary.json"

        if panel.runModal() == .OK, let url = panel.url {
            if let data = dictionaryManager.exportToJSON() {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Entry Row

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term)
                    .font(.body)

                if let pronunciation = entry.pronunciation, !pronunciation.isEmpty {
                    Text(pronunciation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Category badge
            Text(entry.category.capitalized)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(categoryColor.opacity(0.15))
                )
                .foregroundColor(categoryColor)

            // Usage count
            Text("\(entry.frequency)x")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)

            // Auto-learned indicator
            if entry.isAutoLearned {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var categoryColor: Color {
        switch entry.category {
        case "name": return .blue
        case "acronym": return .purple
        case "technical": return .green
        default: return .gray
        }
    }
}

// MARK: - Add Entry Sheet

struct AddDictionaryEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var pronunciation = ""
    @State private var category = "custom"

    var onSave: (String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Dictionary Entry")
                .font(.headline)

            Form {
                TextField("Term", text: $term)
                TextField("Pronunciation (optional)", text: $pronunciation)

                Picker("Category", selection: $category) {
                    ForEach(DictionaryCategory.allCases, id: \.rawValue) { cat in
                        Text(cat.displayName).tag(cat.rawValue)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    guard !term.isEmpty else { return }
                    onSave(term, category)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(term.isEmpty)
            }
        }
        .padding()
        .frame(width: 350, height: 220)
    }
}
