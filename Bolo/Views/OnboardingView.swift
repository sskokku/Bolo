import SwiftUI

/// First-launch onboarding flow that guides the user through:
/// 1. Welcome screen
/// 2. Microphone permission
/// 3. Accessibility permission
/// 4. API key setup
/// 5. Quick test
struct OnboardingView: View {

    @ObservedObject var settings = AppSettings.shared
    @State private var currentStep = 0
    @Environment(\.dismiss) private var dismiss

    // Permission state tracked as reactive @State so the view re-renders
    // when the user grants/denies in the system dialog.
    @State private var micGranted: Bool = MacOSAudioCapture.hasPermission
    @State private var micRequested: Bool = false   // true once we've shown the dialog
    @State private var a11yGranted: Bool = MacOSHotkeyManager.hasAccessibilityPermission()

    // True when the current step allows advancing
    private var canAdvance: Bool {
        switch currentStep {
        case 1: return micGranted          // must grant mic before moving on
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: microphoneStep
                case 2: accessibilityStep
                case 3: apiKeyStep
                case 4: completeStep
                default: completeStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                }

                Spacer()

                // Step indicators
                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { step in
                        Circle()
                            .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep < 4 {
                    Button("Next") {
                        currentStep += 1
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
                } else {
                    Button("Get Started") {
                        settings.hasCompletedOnboarding = true
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 400)
        // Poll accessibility permission while on that step (it requires
        // the user to toggle a switch in System Settings, so we poll).
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if currentStep == 2 {
                a11yGranted = MacOSHotkeyManager.hasAccessibilityPermission()
            }
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Welcome to Bolo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("बोलो — Hindi for \"speak\"")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("Transform your voice into polished, ready-to-use text.\nHold a key, speak naturally, release — done.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: micGranted ? "mic.fill" : "mic.badge.plus")
                .font(.system(size: 50))
                .foregroundColor(micGranted ? .green : .accentColor)
                .animation(.easeInOut, value: micGranted)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.bold)

            Text("Bolo needs access to your microphone to capture your voice for transcription.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if micGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if micRequested {
                // Dialog was shown but user denied — give them a path to fix it
                VStack(spacing: 8) {
                    Label("Microphone access denied", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Open System Settings → Privacy & Security → Microphone and enable Bolo.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Not yet requested — show a prompt button (system dialog fires on tap)
                Button("Grant Microphone Access") {
                    Task {
                        micRequested = true
                        let granted = await MacOSAudioCapture.requestPermission()
                        micGranted = granted
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        // Auto-trigger the system permission dialog as soon as the step appears.
        // This matches the behaviour of iOS apps and avoids an extra button tap.
        .onAppear {
            guard !MacOSAudioCapture.hasPermission, !micRequested else { return }
            Task {
                micRequested = true
                let granted = await MacOSAudioCapture.requestPermission()
                micGranted = granted
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "accessibility")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("Accessibility Access")
                .font(.title2)
                .fontWeight(.bold)

            Text("Bolo needs Accessibility access to:\n- Detect the fn key system-wide\n- Insert text into any application\n- Read selected text for Command Mode")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if a11yGranted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Open System Settings") {
                    MacOSHotkeyManager.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)

                Text("Enable Bolo in:\nSystem Settings → Privacy & Security → Accessibility")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private var apiKeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("API Configuration")
                .font(.title2)
                .fontWeight(.bold)

            Text("Bolo uses Google Gemini to process your voice.\nChoose your authentication method.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Picker("Provider", selection: $settings.authMode) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            if settings.authMode == .geminiDirect {
                VStack(spacing: 8) {
                    SecureField("Paste your API key here", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)

                    Link("Get a free API key at aistudio.google.com",
                         destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Configure Vertex AI in Settings after onboarding.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.hasValidAuth {
                Label("Configuration saved", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding()
    }

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.title2)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                Label("Hold **Ctrl+Shift** to dictate", systemImage: "hand.tap")
                Label("Press **Ctrl+Shift+Space** for long-talk mode", systemImage: "text.bubble")
                Label("Select text + hold **Ctrl+Shift** for commands", systemImage: "wand.and.stars")
            }
            .font(.body)

            Text("Look for the microphone icon in your menu bar.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
