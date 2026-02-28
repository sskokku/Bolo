import SwiftUI

/// Settings window for configuring Bolo.
/// Accessible from the menu bar dropdown or via Cmd+, shortcut.
struct SettingsView: View {

    @ObservedObject var settings = AppSettings.shared
    @State private var isTestingAPI = false
    @State private var apiTestResult: String?
    @State private var apiTestSuccess = false

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            apiTab
                .tabItem {
                    Label("API", systemImage: "key")
                }

            recordingTab
                .tabItem {
                    Label("Recording", systemImage: "mic")
                }

            dictionaryTab
                .tabItem {
                    Label("Dictionary", systemImage: "book")
                }
        }
        .frame(width: 480, height: 360)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Indicator Style", selection: $settings.indicatorStyle) {
                    ForEach(IndicatorStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text("Choose where to show the recording indicator.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }

            Section("Hotkeys") {
                HStack {
                    Text("Push-to-Talk")
                    Spacer()
                    Text("Ctrl+Shift (hold)")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }

                HStack {
                    Text("Long-Talk Toggle")
                    Spacer()
                    Text("Ctrl+Shift+Space")
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if MacOSHotkeyManager.hasAccessibilityPermission() {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Enable") {
                            MacOSHotkeyManager.requestAccessibilityPermission()
                        }
                    }
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    if MacOSAudioCapture.hasPermission {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Text("Grant when prompted")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API Tab

    private var apiTab: some View {
        Form {
            Section("Gemini API Configuration") {
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Get your free API key:")
                    Link("aistudio.google.com",
                         destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .foregroundColor(.accentColor)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Picker("Model", selection: $settings.model) {
                    Text("Gemini 2.5 Flash (Recommended)").tag("gemini-2.5-flash")
                    Text("Gemini 2.5 Pro").tag("gemini-2.5-pro")
                }

                HStack {
                    Button(isTestingAPI ? "Testing..." : "Test Connection") {
                        testAPIConnection()
                    }
                    .disabled(settings.apiKey.isEmpty || isTestingAPI)

                    if let result = apiTestResult {
                        Label(result, systemImage: apiTestSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(apiTestSuccess ? .green : .red)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording Tab

    private var recordingTab: some View {
        Form {
            Section("Recording") {
                Picker("Max Duration", selection: $settings.maxRecordingDuration) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("3 minutes").tag(TimeInterval(180))
                    Text("5 minutes").tag(TimeInterval(300))
                }

                Toggle("Enable Command Mode", isOn: $settings.enableCommandMode)

                if settings.enableCommandMode {
                    Text("Select text, then hold fn and speak a command to transform it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        Form {
            Section("Personal Dictionary") {
                Toggle("Auto-learn Words", isOn: $settings.autoLearnDictionary)

                Text("Automatically adds frequently used terms to your dictionary for better recognition.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Open Dictionary Manager...") {
                    NotificationCenter.default.post(name: .openDictionary, object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API Test

    private func testAPIConnection() {
        isTestingAPI = true
        apiTestResult = nil

        Task {
            let client = GeminiClient(apiKey: settings.apiKey, model: settings.model)

            do {
                // Send a simple text-only request to test the API key
                let result = try await client.processCommand(
                    selectedText: "Hello world",
                    command: "repeat this exactly"
                )

                await MainActor.run {
                    apiTestSuccess = true
                    apiTestResult = "Connected successfully"
                    isTestingAPI = false
                }
            } catch {
                await MainActor.run {
                    apiTestSuccess = false
                    apiTestResult = error.localizedDescription
                    isTestingAPI = false
                }
            }
        }
    }
}
