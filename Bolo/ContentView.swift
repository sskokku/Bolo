//
//  ContentView.swift
//  Bolo
//

import SwiftUI
import SwiftData
import ApplicationServices

struct MenuBarContent: View {
    @Environment(DictationController.self) private var dictation
    @Environment(UsageStats.self) private var stats
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transcription.timestamp, order: .reverse) private var allTranscriptions: [Transcription]

    @State private var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @State private var showHistory: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            wordCounter
            if !accessibilityTrusted {
                accessibilityWarning
            }
            recordButton
            statusOrResult
            if !allTranscriptions.isEmpty {
                Divider()
                historySection
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { accessibilityTrusted = AXIsProcessTrusted() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Bolo").font(.headline)
            Text("on-device")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15), in: Capsule())
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Bolo")
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var wordCounter: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.word.spacing")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(stats.totalWords.formatted()) words")
                    .font(.headline)
                    .monospacedDigit()
                Text("\(stats.totalDictations.formatted()) dictations · lifetime")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility access not granted", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("⌃⇧ push-to-talk and auto-paste won't work until you grant Accessibility access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Grant access") {
                    HotkeyMonitor.promptForAccessibility()
                }
                Button("Open System Settings") {
                    HotkeyMonitor.openAccessibilityPane()
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var recordButton: some View {
        switch dictation.state {
        case .idle, .result, .failure:
            Button {
                Task { await dictation.start() }
            } label: {
                Label("Start recording", systemImage: "mic.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])

        case .recording:
            Button {
                Task { await dictation.finish() }
            } label: {
                Label("Stop & transcribe", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(.red)
            .keyboardShortcut(.space, modifiers: [])

        case .transcribing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var statusOrResult: some View {
        switch dictation.state {
        case .idle:
            Text("Hold ⌃⇧ anywhere to record. Or press Space here to toggle.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .recording:
            recordingIndicator

        case .transcribing:
            EmptyView()

        case .result(let text):
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(8)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Text("Copied to clipboard — paste with ⌘V.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy again") { dictation.copyToClipboard() }
                        .controlSize(.small)
                }
            }

        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(4)
        }
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 32, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.red)
                Text("Release ⌃⇧ or press Space to stop")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    showHistory.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text("Recent (\(allTranscriptions.count))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if showHistory {
                    Button("Clear all", role: .destructive) { clearHistory() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
            if showHistory {
                ForEach(Array(allTranscriptions.prefix(5))) { t in
                    HistoryRow(transcription: t) { delete(t) }
                }
            }
        }
    }

    private func clearHistory() {
        for t in allTranscriptions { modelContext.delete(t) }
        try? modelContext.save()
    }

    private func delete(_ t: Transcription) {
        modelContext.delete(t)
        try? modelContext.save()
    }
}

private struct HistoryRow: View {
    let transcription: Transcription
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(transcription.text)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcription.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}
