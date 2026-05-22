//
//  SettingsView.swift
//  Bolo
//

import SwiftUI
import ApplicationServices
import ServiceManagement

struct SettingsView: View {
    @Environment(UsageStats.self) private var stats

    @State private var accessibilityTrusted: Bool = AXIsProcessTrusted()
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var speechStatus: SpeechStatus = .idle

    enum SpeechStatus {
        case idle
        case running
        case ready(String)
        case failure(String)
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            statsTab
                .tabItem { Label("Stats", systemImage: "chart.bar") }

            permissionsTab
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 580, height: 460)
        .onAppear {
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Push-to-talk")
                    Spacer()
                    Text("Hold ⌃⇧").font(.system(.body, design: .monospaced))
                }
                Text("Hold Control + Shift anywhere on macOS to record. Release to transcribe and paste at your cursor. Requires Accessibility permission (see Permissions tab).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Speech engine") {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Apple Speech — on-device, no network")
                }
                Text("Bolo transcribes your speech as-is using the macOS Speech framework. Nothing leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check / download model") {
                        Task { await checkSpeech() }
                    }
                    .disabled(isCheckingSpeech)
                    speechStatusView
                }
            }

            Section("Startup") {
                Toggle("Launch Bolo at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Works best when Bolo is installed in /Applications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var statsTab: some View {
        Form {
            Section("Lifetime") {
                LabeledContent("Total words spoken", value: stats.totalWords.formatted())
                LabeledContent("Total dictations", value: stats.totalDictations.formatted())
                Text("Cumulative across the life of the app. Clearing transcription history does not reset these counters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var permissionsTab: some View {
        Form {
            Section("Accessibility") {
                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text(accessibilityTrusted ? "Granted" : "Not granted")
                    Spacer()
                    Button("Refresh") { accessibilityTrusted = AXIsProcessTrusted() }
                        .controlSize(.small)
                }
                if !accessibilityTrusted {
                    HStack {
                        Button("Request access") {
                            HotkeyMonitor.promptForAccessibility()
                        }
                        Button("Open System Settings") {
                            HotkeyMonitor.openAccessibilityPane()
                        }
                    }
                }
                Text("Required for the ⌃⇧ push-to-talk hotkey and auto-paste into the frontmost app. After granting, quit and relaunch Bolo for the change to take effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var isCheckingSpeech: Bool {
        if case .running = speechStatus { return true }
        return false
    }

    @ViewBuilder
    private var speechStatusView: some View {
        switch speechStatus {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .ready(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func checkSpeech() async {
        speechStatus = .running
        if #available(macOS 26, *) {
            let provider = AppleSpeechProvider()
            do {
                try await provider.testConnection()
                speechStatus = .ready("Apple Speech ready (\(Locale.current.identifier))")
            } catch {
                speechStatus = .failure(error.localizedDescription)
            }
        } else {
            speechStatus = .failure("Requires macOS 26 or later.")
        }
    }
}
