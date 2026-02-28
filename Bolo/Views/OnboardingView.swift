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
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.bold)

            Text("Bolo needs access to your microphone to capture your voice for transcription.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            if MacOSAudioCapture.hasPermission {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant Microphone Access") {
                    Task {
                        _ = await MacOSAudioCapture.requestPermission()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
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

            if MacOSHotkeyManager.hasAccessibilityPermission() {
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

            Text("Gemini API Key")
                .font(.title2)
                .fontWeight(.bold)

            Text("Bolo uses Google Gemini to process your voice.\nA free API key is available.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                SecureField("Paste your API key here", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                Link("Get a free API key at aistudio.google.com",
                     destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                    .font(.caption)
            }

            if settings.hasValidAPIKey {
                Label("API key saved", systemImage: "checkmark.circle.fill")
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
