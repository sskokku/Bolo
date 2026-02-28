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
    /// The app that was frontmost when recording started — we'll re-activate it for text insertion.
    private var targetApp: NSRunningApplication?

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

    func applicationWillTerminate(_ notification: Notification) {
        ErrorLogger.shared.logInfo(category: .app, message: "Bolo shutting down")
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

        // Apply initial indicator style (floating pill, menu bar, or both)
        applyIndicatorStyle(settings.indicatorStyle)

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
            if hotkeyManager.usingEventTap {
                logger.info("Hotkey manager started — using CGEvent tap (full functionality)")
                ErrorLogger.shared.logInfo(category: .hotkey, message: "Hotkey manager started — CGEvent tap (full)")
            } else {
                logger.info("Hotkey manager started — using NSEvent monitors (fallback, limited)")
                ErrorLogger.shared.logWarning(category: .hotkey, message: "Hotkey manager using NSEvent fallback (limited)")
            }
        } else {
            hotkeyStartSucceeded = false
            logger.error("Hotkey manager FAILED to start — no hotkey detection available")
            ErrorLogger.shared.logError(category: .hotkey, message: "Hotkey manager FAILED to start — no hotkey detection")
        }
    }

    private func checkPermissions() {
        Task {
            // Check microphone permission
            if !MacOSAudioCapture.hasPermission {
                let granted = await MacOSAudioCapture.requestPermission()
                if !granted {
                    ErrorLogger.shared.logError(category: .audio, message: "Microphone permission denied by user")
                    await MainActor.run {
                        appState.state = .error(.microphonePermissionDenied)
                    }
                }
            }

            // If hotkeys completely failed (neither CGEvent nor NSEvent worked),
            // prompt for Accessibility permission
            if !hotkeyStartSucceeded {
                logger.warning("Hotkey manager failed entirely — prompting for Accessibility permission")
                ErrorLogger.shared.logError(category: .hotkey, message: "Accessibility permission denied — hotkeys unavailable")
                MacOSHotkeyManager.requestAccessibilityPermission()
                await MainActor.run {
                    appState.state = .error(.accessibilityPermissionDenied)
                }
            } else if !hotkeyManager.usingEventTap {
                // NSEvent fallback is active — hotkeys work but we should still
                // request Accessibility for full text insertion capability.
                // Don't block the app though; just prompt gently.
                if !MacOSHotkeyManager.hasAccessibilityPermission() {
                    logger.info("Using NSEvent fallback — requesting Accessibility for text insertion")
                    MacOSHotkeyManager.requestAccessibilityPermission()
                }
            }

            // Check API key — if missing, open settings to prompt entry
            if !settings.hasValidAPIKey {
                ErrorLogger.shared.logWarning(category: .api, message: "API key not configured — prompting user")
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

            // Remember which app the user was in — we'll re-activate it for text insertion
            targetApp = NSWorkspace.shared.frontmostApplication
            logger.info("Target app for insertion: \(self.targetApp?.localizedName ?? "unknown")")

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
                ErrorLogger.shared.logInfo(category: .audio, message: "Starting audio capture — mode: \(actualMode)")
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
                if settings.indicatorStyle.showsFloatingPill {
                    floatingToolbar.show()
                }
            } catch {
                logger.error("Audio capture failed: \(error.localizedDescription)")
                ErrorLogger.shared.logError(category: .audio, message: "Audio capture failed to start", error: error)
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
            appState.resetWaveform()

            // Validate recording length
            guard appState.recordingDuration > 0.3 else {
                ErrorLogger.shared.logWarning(category: .audio, message: "Recording too short: \(appState.recordingDuration)s")
                appState.state = .error(.audioTooShort)
                resetToIdleAfterDelay()
                return
            }

            guard let client = geminiClient else {
                ErrorLogger.shared.logError(category: .api, message: "No Gemini client — API key missing")
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
                        ErrorLogger.shared.logError(category: .insertion, message: "Command mode: no selected text available")
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
                ErrorLogger.shared.logInfo(category: .app, message: "Transcription successful — \(resultText.count) chars, mode: \(mode)")

                // Insert text
                appState.state = .inserting

                // Always copy to clipboard first as a safety net.
                // If AX insertion works, the clipboard is a bonus backup.
                // If it fails, the user can Cmd+V manually.
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(resultText, forType: .string)
                logger.info("Text copied to clipboard as safety net")

                // Re-activate the app the user was in when they started recording.
                // During the 2-3 seconds of API processing, focus may have shifted.
                let target = self.targetApp
                if let target, !target.isTerminated {
                    logger.info("Re-activating target app: \(target.localizedName ?? "unknown") (PID \(target.processIdentifier))")
                    target.activate()

                    // Poll until the app is actually frontmost (up to 500ms)
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                            break
                        }
                    }
                    // Extra settle time for the window to fully accept keyboard input
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }

                // Get target PID for direct event delivery to the correct process
                let targetPID: pid_t? = (target != nil && !target!.isTerminated) ? target!.processIdentifier : nil

                // Try AX-based text insertion if Accessibility is granted
                let trusted = AXIsProcessTrusted()
                logger.info("Attempting text insertion — AXIsProcessTrusted: \(trusted), targetPID: \(targetPID.map { String($0) } ?? "nil")")

                if trusted {
                    if case .command = mode {
                        try textInsertion.replaceSelectedText(with: resultText, targetPID: targetPID)
                    } else {
                        try textInsertion.insertText(resultText, targetPID: targetPID)
                    }
                } else {
                    // No Accessibility — show one-time alert
                    showAccessibilityAlert(transcribedText: resultText)
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

                ErrorLogger.shared.logError(
                    category: .app,
                    message: "Recording pipeline failed: \(error.localizedDescription)",
                    appState: String(describing: appError)
                )
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
            self.appState.pushAudioLevel(level)
        }
    }

    nonisolated func audioCaptureDidFail(_ error: Error) {
        ErrorLogger.shared.logError(category: .audio, message: "Audio capture delegate failure", error: error)
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

        // Apply indicator style changes
        applyIndicatorStyle(settings.indicatorStyle)
    }

    // MARK: - Indicator Style

    /// Apply the indicator style — show/hide floating pill and enable/disable live menu bar indicator.
    private func applyIndicatorStyle(_ style: IndicatorStyle) {
        if style.showsFloatingPill {
            floatingToolbar.show()
        } else {
            floatingToolbar.hide()
        }

        if style.showsMenuBarIndicator {
            menuBarController.enableLiveIndicator()
        } else {
            menuBarController.disableLiveIndicator()
        }
    }

    // MARK: - Accessibility Alert

    /// Shows a one-time alert explaining that Accessibility permission is needed
    /// for text insertion. The transcribed text is already on the clipboard.
    private var hasShownAccessibilityAlert = false

    private func showAccessibilityAlert(transcribedText: String) {
        // Copy is already done by the caller — just show the alert once
        guard !hasShownAccessibilityAlert else {
            // Subsequent times, just show a notification
            logger.info("Text copied to clipboard (Accessibility still not granted)")
            return
        }
        hasShownAccessibilityAlert = true

        let alert = NSAlert()
        alert.messageText = "Text Copied to Clipboard"
        alert.informativeText = """
        Your transcription was successful! The text has been copied to your clipboard — press Cmd+V to paste it.

        To enable automatic text insertion, Bolo needs Accessibility permission:

        1. Open System Settings → Privacy & Security → Accessibility
        2. Click "+" and add Bolo from:
           ~/Library/Developer/Xcode/DerivedData/Bolo-.../Build/Products/Debug/Bolo.app
        3. Make sure the toggle is ON

        After granting permission, Bolo will insert text directly at your cursor.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            MacOSHotkeyManager.requestAccessibilityPermission()
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
