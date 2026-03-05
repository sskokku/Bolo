import SwiftUI

/// Settings window for configuring Bolo.
/// Accessible from the menu bar dropdown or via Cmd+, shortcut.
struct SettingsView: View {

    @ObservedObject var settings = AppSettings.shared
    @State private var isTestingAPI = false
    @State private var apiTestResult: String?
    @State private var apiTestSuccess = false
    @State private var isSigningIn = false
    @State private var signInError: String?

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

            loggingTab
                .tabItem {
                    Label("Logging", systemImage: "doc.text")
                }
        }
        .frame(width: 480, height: 460)
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
            Section("Authentication Method") {
                Picker("Provider", selection: $settings.authMode) {
                    ForEach(AuthMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.authMode) { _ in
                    // Clear test result when switching modes
                    apiTestResult = nil
                }
            }

            if settings.authMode == .geminiDirect {
                geminiDirectSection
            } else {
                vertexAIConfigSection
                vertexAISignInSection
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    Text("Gemini 2.5 Flash (Recommended)").tag("gemini-2.5-flash")
                    Text("Gemini 2.5 Pro").tag("gemini-2.5-pro")
                }

                HStack {
                    Button(isTestingAPI ? "Testing..." : "Test Connection") {
                        testAPIConnection()
                    }
                    .disabled(!settings.hasValidAuth || isTestingAPI)

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

    // MARK: - Gemini Direct Section

    private var geminiDirectSection: some View {
        Section("Gemini API Key") {
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
        }
    }

    // MARK: - Vertex AI Sections

    private var vertexAIConfigSection: some View {
        Section("Vertex AI Configuration") {
            TextField("GCP Project ID", text: $settings.vertexProjectID)
                .textFieldStyle(.roundedBorder)

            Picker("Region", selection: $settings.vertexRegion) {
                Text("us-central1").tag("us-central1")
                Text("us-east1").tag("us-east1")
                Text("us-west1").tag("us-west1")
                Text("europe-west1").tag("europe-west1")
                Text("asia-northeast1").tag("asia-northeast1")
            }

            TextField("OAuth Client ID", text: $settings.vertexOAuthClientID)
                .textFieldStyle(.roundedBorder)

            Text("Create a Desktop OAuth Client ID in your GCP Console under APIs & Services → Credentials.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var vertexAISignInSection: some View {
        Section("Google Account") {
            if OAuthTokenManager.shared.isSignedIn {
                HStack {
                    VStack(alignment: .leading) {
                        Label("Signed in", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        if let email = OAuthTokenManager.shared.userEmail {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign Out") {
                        OAuthTokenManager.shared.clearTokens()
                        signInError = nil
                        apiTestResult = nil
                    }
                    .foregroundColor(.red)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button(isSigningIn ? "Signing in..." : "Sign in with Google") {
                        performSignIn()
                    }
                    .disabled(isSigningIn || settings.vertexOAuthClientID.isEmpty)

                    if let error = signInError {
                        Label(error, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Text("Opens your browser for Google Workspace sign-in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
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

    // MARK: - Logging Tab

    private var loggingTab: some View {
        Form {
            Section("Error Logging") {
                Toggle("Enable Logging", isOn: $settings.enableLogging)

                Text("Structured logs are written to ~/Library/Application Support/Bolo/Logs/bolo.log")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Storage") {
                Picker("Max Log File Size", selection: $settings.maxLogFileSize) {
                    Text("1 MB").tag(1)
                    Text("5 MB (Recommended)").tag(5)
                    Text("10 MB").tag(10)
                    Text("25 MB").tag(25)
                }

                Text("When the log file exceeds this size, it is automatically purged and you'll be notified.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Current Size")
                    Spacer()
                    Text(logFileSizeText)
                        .foregroundColor(.secondary)
                }

                Text("Logs are also auto-purged daily at 11:59 PM.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Actions") {
                HStack {
                    Button("Reveal Log File in Finder") {
                        let url = ErrorLogger.shared.getLogFileURL()
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }

                    Spacer()

                    Button("Purge Log Now") {
                        ErrorLogger.shared.purgeLogFile()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var logFileSizeText: String {
        let bytes = ErrorLogger.shared.getLogFileSize()
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.2f MB", Double(bytes) / 1_048_576.0)
        }
    }

    // MARK: - API Test

    private func testAPIConnection() {
        isTestingAPI = true
        apiTestResult = nil

        Task {
            let client: any TranscriptionProvider
            switch settings.authMode {
            case .geminiDirect:
                client = GeminiClient(apiKey: settings.apiKey, model: settings.model)
            case .vertexAI:
                client = VertexAIClient(
                    projectID: settings.vertexProjectID,
                    region: settings.vertexRegion,
                    model: settings.model
                )
            }

            do {
                // Send a simple text-only request to test the connection
                let _ = try await client.processCommand(
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

    // MARK: - OAuth Sign-In

    private func performSignIn() {
        isSigningIn = true
        signInError = nil

        Task {
            do {
                let handler = OAuthSignInHandler(clientID: settings.vertexOAuthClientID)
                let tokens = try await handler.signIn()
                OAuthTokenManager.shared.storeTokens(tokens)

                await MainActor.run {
                    isSigningIn = false
                    signInError = nil
                    // Trigger settings change to refresh the transcription provider
                    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
                }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    signInError = error.localizedDescription
                }
            }
        }
    }
}
