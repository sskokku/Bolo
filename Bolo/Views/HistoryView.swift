import SwiftUI

/// View showing recent transcription history.
struct HistoryView: View {

    @State private var entries: [HistoryEntry] = []
    @State private var searchText = ""

    private let historyManager = HistoryManager()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                TextField("Search history...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _, newValue in
                        refreshEntries(query: newValue)
                    }

                if !entries.isEmpty {
                    Button("Clear All") {
                        historyManager.clearAll()
                        refreshEntries()
                    }
                    .foregroundColor(.red)
                }
            }
            .padding()

            Divider()

            // Entry list
            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No history yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Your transcriptions will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        HistoryEntryRow(entry: entry)
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
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 500, height: 400)
        .onAppear { refreshEntries() }
    }

    private func refreshEntries(query: String = "") {
        if query.isEmpty {
            entries = historyManager.getRecentEntries()
        } else {
            entries = historyManager.searchEntries(query: query)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            historyManager.deleteEntry(id: entries[index].id)
        }
        refreshEntries(query: searchText)
    }
}

// MARK: - History Entry Row

struct HistoryEntryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Transcription text
            Text(entry.text)
                .font(.body)
                .lineLimit(3)

            // Metadata row
            HStack(spacing: 8) {
                // Mode badge
                Text(entry.mode)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(modeBadgeColor.opacity(0.15))
                    )
                    .foregroundColor(modeBadgeColor)

                // App name
                if let appName = entry.appName {
                    Text(appName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Timestamp
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Duration
                if entry.duration > 0 {
                    Text(formatDuration(entry.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy to Clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
        }
    }

    private var modeBadgeColor: Color {
        switch entry.mode {
        case "Push-to-Talk": return .blue
        case "Long-Talk": return .green
        case "Command": return .purple
        default: return .gray
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = Int(duration)
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
