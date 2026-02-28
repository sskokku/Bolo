import SwiftUI
import AppKit
import os.log

/// Unified logger for Bolo — messages appear in Console.app under subsystem "com.bolo.app".
private let logger = Logger(subsystem: "com.bolo.app", category: "AppDelegate")

/// Bolo (बोलो) - Voice Dictation App
/// Main application entry point. Bolo runs as a menu bar app (LSUIElement)
/// and provides system-wide voice-to-text dictation using Google Gemini.
@main
struct BoloApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene accessible via menu bar > Settings
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

/// AppDelegate handles the menu bar lifecycle, hotkey registration,
/// and coordinates between audio capture, Gemini API, and text insertion.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, AudioCaptureDelegate {

    // MARK: - Properties

    private var menuBarController: MenuBarController!
    private var floatingToolbar: FloatingToolbarController!
    private var hotkeyManager: MacOSHotkeyManager!
    private var audioCapture: MacOSAudioCapture!
    private var textInsertion: MacOSTextInsertion!
    private var geminiClient: GeminiClient?
    private var dictionaryManager: DictionaryManager!
    private var historyManager: HistoryManager!
    private var recordingTimer: Timer?
    private var onboardingWindow: NSWindow?

    let appState = AppState()
    let settings = AppSettings.shared

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupComponents()
        checkPermissions()

        // Show onboarding on first launch
        if !settings.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    // MARK: - Setup

    private func setupComponents() {
        // Initialize managers
        dictionaryManager = DictionaryManager()
        historyManager = HistoryManager()
        audioCapture = MacOSAudioCapture()
        audioCapture.delegate = self
        textInsertion = MacOSTextInsertion()

        // Initialize UI
        menuBarController = MenuBarController(appState: appState)
        floatingToolbar = FloatingToolbarController(appState: appState)

        if settings.showFloatingToolbar {
            floatingToolbar.show()
        }

        // Initialize Gemini client if API key exists
        refreshGeminiClient()

        // Setup hotkeys
        setupHotkeys()

        // Observe settings changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    private func refreshGeminiClient() {
        guard settings.hasValidAPIKey else {
            geminiClient = nil
            return
        }
        geminiClient = GeminiClient(apiKey: settings.apiKey, model: settings.model)
    }

    private var hotkeyStartSucceeded = false

    private func setupHotkeys() {
        hotkeyManager = MacOSHotkeyManager()

        hotkeyManager.onPushToTalkStart = { [weak self] in
            self?.startRecording(mode: .pushToTalk)
        }

        hotkeyManager.onPushToTalkEnd = { [weak self] in
            self?.stopRecordingAndProcess()
        }

        hotkeyManager.onLongTalkToggle = { [weak self] in
            self?.toggleLongTalk()
        }

        if hotkeyManager.start() {
            hotkeyStartSucceeded = true
            logger.info("Hotkey event tap created successfully")
        } else {
            hotkeyStartSucceeded = false
            logger.error("Hotkey event tap FAILED — will prompt for Accessibility permission")
        }
    }

    private func checkPermissions() {
        Task {
            // Check microphone permission
            if !MacOSAudioCapture.hasPermission {
                let granted = await MacOSAudioCapture.requestPermission()
                if !granted {
                    await MainActor.run {
                        appState.state = .error(.microphonePermissionDenied)
                    }
                }
            }

            // Only prompt for Accessibility if the event tap actually failed.
            // Don't rely on AXIsProcessTrusted() alone — after Xcode rebuilds,
            // the code signature changes and macOS reports untrusted even though
            // the event tap works fine.
            if !hotkeyStartSucceeded {
                logger.warning("Event tap failed — prompting for Accessibility permission")
                MacOSHotkeyManager.requestAccessibilityPermission()
                await MainActor.run {
                    appState.state = .error(.accessibilityPermissionDenied)
                }
            }

            // Check API key — if missing, open settings to prompt entry
            if !settings.hasValidAPIKey {
                await MainActor.run {
                    appState.state = .error(.apiKeyMissing)
                    menuBarController.openSettingsWindow()
                }
            }
        }
    }

    // MARK: - Recording Control

    private func startRecording(mode: RecordingMode) {
        Task { @MainActor in
            logger.info("startRecording called — mode: \(String(describing: mode)), current state: \(String(describing: self.appState.state))")
            guard case .idle = appState.state else {
                logger.warning("startRecording aborted — state is not idle")
                return
            }

            // Check if command mode should be used
            let actualMode: RecordingMode
            if mode == .pushToTalk,
               settings.enableCommandMode,
               let _ = textInsertion.getSelectedText() {
                actualMode = .command
            } else {
                actualMode = mode
            }

            do {
                logger.info("Starting audio capture — mode: \(String(describing: actualMode))")
                try audioCapture.startRecording()
                appState.state = .recording(mode: actualMode)
                appState.recordingDuration = 0

                // Start duration timer
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.appState.recordingDuration += 0.1

                        // Auto-stop at max duration
                        if self.appState.recordingDuration >= self.settings.maxRecordingDuration {
                            self.stopRecordingAndProcess()
                        }
                    }
                }

                menuBarController.updateIcon(for: appState.state)
                if settings.showFloatingToolbar {
                    floatingToolbar.show()
                }
            } catch {
                logger.error("Audio capture failed: \(error.localizedDescription)")
                appState.state = .error(.microphonePermissionDenied)
            }
        }
    }

    private func stopRecordingAndProcess() {
        Task { @MainActor in
            logger.info("stopRecordingAndProcess called — current state: \(String(describing: self.appState.state))")
            guard case .recording(let mode) = appState.state else {
                logger.warning("stopRecordingAndProcess aborted — not recording")
                return
            }

            // Stop timer
            recordingTimer?.invalidate()
            recordingTimer = nil

            // Stop audio capture and get WAV data
            let wavData = audioCapture.stopRecording()

            // Validate recording length
            guard appState.recordingDuration > 0.3 else {
                appState.state = .error(.audioTooShort)
                resetToIdleAfterDelay()
                return
            }

            guard let client = geminiClient else {
                appState.state = .error(.apiKeyMissing)
                resetToIdleAfterDelay()
                return
            }

            appState.state = .processing
            menuBarController.updateIcon(for: appState.state)
            logger.info("Sending \(wavData.count) bytes of audio to Gemini API")

            do {
                let resultText: String

                switch mode {
                case .pushToTalk, .longTalk:
                    // Get context from active text field
                    let context = textInsertion.getTextContext()
                    let dictionary = dictionaryManager.getTopEntries()

                    resultText = try await client.transcribe(
                        audio: wavData,
                        context: context,
                        dictionary: dictionary
                    )

                case .command:
                    // Get selected text for command mode
                    guard let selectedText = textInsertion.getSelectedText() else {
                        appState.state = .error(.insertionFailed)
                        resetToIdleAfterDelay()
                        return
                    }

                    // The audio is the voice command
                    // First transcribe the command
                    let command = try await client.transcribe(audio: wavData)

                    // Then process the command on the selected text
                    resultText = try await client.processCommand(
                        selectedText: selectedText,
                        command: command
                    )
                }

                logger.info("Transcription result: \(resultText.prefix(100))")

                // Insert text
                appState.state = .inserting

                if case .command = mode {
                    try textInsertion.replaceSelectedText(with: resultText)
                } else {
                    try textInsertion.insertText(resultText)
                }

                // Save to transcription history
                let appContext = textInsertion.getActiveAppContext()
                let entry = TranscriptionResult(
                    text: resultText,
                    mode: mode,
                    duration: appState.recordingDuration,
                    appContext: appContext
                ).toHistoryEntry()
                historyManager.addEntry(entry)

                // Update dictionary usage for recognized terms
                for term in dictionaryManager.getTopEntries() {
                    if resultText.localizedCaseInsensitiveContains(term) {
                        dictionaryManager.incrementUsage(term: term)
                    }
                }

                appState.state = .idle
                menuBarController.updateIcon(for: appState.state)

            } catch {
                let appError: AppError
                if let geminiError = error as? GeminiError {
                    switch geminiError {
                    case .invalidAPIKey:
                        appError = .apiKeyMissing
                    case .networkError:
                        appError = .networkError
                    case .apiError(let msg):
                        appError = .apiError(msg)
                    default:
                        appError = .apiError(error.localizedDescription)
                    }
                } else {
                    appError = .apiError(error.localizedDescription)
                }

                appState.state = .error(appError)
                menuBarController.updateIcon(for: appState.state)
                resetToIdleAfterDelay()
            }
        }
    }

    private func toggleLongTalk() {
        Task { @MainActor in
            if appState.isLongTalkActive {
                // Stopping long talk
                appState.isLongTalkActive = false
                stopRecordingAndProcess()
            } else {
                // Starting long talk
                appState.isLongTalkActive = true
                startRecording(mode: .longTalk)
            }
        }
    }

    private func resetToIdleAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if case .error = self.appState.state {
                self.appState.state = .idle
                self.menuBarController.updateIcon(for: self.appState.state)
            }
        }
    }

    // MARK: - AudioCaptureDelegate

    nonisolated func audioCaptureDidReceiveBuffer(_ pcmData: Data) {
        // Buffer handled internally by AudioCapture
    }

    nonisolated func audioCaptureDidUpdateLevel(_ level: Float) {
        Task { @MainActor in
            self.appState.audioLevel = level
        }
    }

    nonisolated func audioCaptureDidFail(_ error: Error) {
        Task { @MainActor in
            self.appState.state = .error(.microphonePermissionDenied)
        }
    }

    // MARK: - Notifications

    @objc private func settingsDidChange() {
        refreshGeminiClient()

        // If the user just entered their API key, clear the apiKeyMissing error
        // so recording can proceed. Without this, the state stays stuck in .error
        // and startRecording() silently returns.
        if settings.hasValidAPIKey, case .error(.apiKeyMissing) = appState.state {
            logger.info("API key entered — resetting state from error to idle")
            appState.state = .idle
            menuBarController.updateIcon(for: appState.state)
        }

        if settings.showFloatingToolbar {
            floatingToolbar.show()
        } else {
            floatingToolbar.hide()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let onboardingView = OnboardingView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Bolo"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }
}
