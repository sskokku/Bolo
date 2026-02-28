import Foundation
import Security
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "SettingsModel")

// MARK: - Indicator Style

/// The visual indicator style shown during recording.
enum IndicatorStyle: String, CaseIterable, Identifiable {
    case floatingPill = "floating_pill"
    case menuBar = "menu_bar"
    case both = "both"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .floatingPill: return "Floating Pill"
        case .menuBar: return "Menu Bar"
        case .both: return "Both"
        }
    }

    var showsFloatingPill: Bool {
        self == .floatingPill || self == .both
    }

    var showsMenuBarIndicator: Bool {
        self == .menuBar || self == .both
    }
}

// MARK: - Settings Keys

/// UserDefaults keys for app preferences.
enum SettingsKey {
    static let apiKey = "gemini_api_key"
    static let model = "gemini_model"
    static let pushToTalkKey = "hotkey_push_to_talk"
    static let longTalkKey = "hotkey_long_talk"
    static let showFloatingToolbar = "show_floating_toolbar" // legacy, migrated
    static let indicatorStyle = "indicator_style"
    static let autoLearnDictionary = "auto_learn_dictionary"
    static let maxRecordingDuration = "max_recording_duration"
    static let enableCommandMode = "enable_command_mode"
    static let hasCompletedOnboarding = "has_completed_onboarding"
    static let launchAtLogin = "launch_at_login"
    static let maxLogFileSize = "max_log_file_size"
    static let enableLogging = "enable_logging"
}

// MARK: - Settings Defaults

/// Default values for all settings.
enum SettingsDefaults {
    static let model = "gemini-2.5-flash"
    static let pushToTalkKey = "ctrl+shift"
    static let longTalkKey = "ctrl+shift+space"
    static let showFloatingToolbar = true // legacy
    static let indicatorStyle: IndicatorStyle = .floatingPill
    static let autoLearnDictionary = true
    static let maxRecordingDuration: TimeInterval = 300 // 5 minutes
    static let enableCommandMode = true
    static let hasCompletedOnboarding = false
    static let launchAtLogin = false
    static let maxLogFileSize = 5 // MB
    static let enableLogging = true
}

// MARK: - Settings

/// Singleton settings manager. Persists preferences to UserDefaults
/// and stores the API key securely in the macOS Keychain.
@MainActor
class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Published Properties

    @Published var apiKey: String {
        didSet { KeychainHelper.save(apiKey, for: SettingsKey.apiKey) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: SettingsKey.model) }
    }

    @Published var indicatorStyle: IndicatorStyle {
        didSet { UserDefaults.standard.set(indicatorStyle.rawValue, forKey: SettingsKey.indicatorStyle) }
    }

    /// Backward-compatible computed property.
    var showFloatingToolbar: Bool { indicatorStyle.showsFloatingPill }
    var showMenuBarIndicator: Bool { indicatorStyle.showsMenuBarIndicator }

    @Published var autoLearnDictionary: Bool {
        didSet { UserDefaults.standard.set(autoLearnDictionary, forKey: SettingsKey.autoLearnDictionary) }
    }

    @Published var maxRecordingDuration: TimeInterval {
        didSet { UserDefaults.standard.set(maxRecordingDuration, forKey: SettingsKey.maxRecordingDuration) }
    }

    @Published var enableCommandMode: Bool {
        didSet { UserDefaults.standard.set(enableCommandMode, forKey: SettingsKey.enableCommandMode) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: SettingsKey.hasCompletedOnboarding) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: SettingsKey.launchAtLogin)
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    @Published var maxLogFileSize: Int {
        didSet { UserDefaults.standard.set(maxLogFileSize, forKey: SettingsKey.maxLogFileSize) }
    }

    @Published var enableLogging: Bool {
        didSet { UserDefaults.standard.set(enableLogging, forKey: SettingsKey.enableLogging) }
    }

    // MARK: - Computed

    var hasValidAPIKey: Bool {
        !apiKey.isEmpty
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Failed to update launch-at-login: \(error.localizedDescription)")
            ErrorLogger.shared.logError(category: .settings, message: "Failed to update launch-at-login", error: error)
        }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard
        self.apiKey = KeychainHelper.load(SettingsKey.apiKey) ?? ""
        self.model = defaults.string(forKey: SettingsKey.model) ?? SettingsDefaults.model
        // Migrate from old showFloatingToolbar bool to new indicatorStyle enum
        let resolvedStyle: IndicatorStyle
        if let rawStyle = defaults.string(forKey: SettingsKey.indicatorStyle),
           let style = IndicatorStyle(rawValue: rawStyle) {
            resolvedStyle = style
        } else {
            let oldShowToolbar = defaults.object(forKey: SettingsKey.showFloatingToolbar) as? Bool
                ?? SettingsDefaults.showFloatingToolbar
            resolvedStyle = oldShowToolbar ? .floatingPill : .menuBar
            defaults.set(resolvedStyle.rawValue, forKey: SettingsKey.indicatorStyle)
        }
        self.indicatorStyle = resolvedStyle
        self.autoLearnDictionary = defaults.object(forKey: SettingsKey.autoLearnDictionary) as? Bool ?? SettingsDefaults.autoLearnDictionary
        self.maxRecordingDuration = defaults.object(forKey: SettingsKey.maxRecordingDuration) as? TimeInterval ?? SettingsDefaults.maxRecordingDuration
        self.enableCommandMode = defaults.object(forKey: SettingsKey.enableCommandMode) as? Bool ?? SettingsDefaults.enableCommandMode
        self.hasCompletedOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        self.launchAtLogin = defaults.bool(forKey: SettingsKey.launchAtLogin)
        let storedLogSize = defaults.integer(forKey: SettingsKey.maxLogFileSize)
        self.maxLogFileSize = storedLogSize > 0 ? storedLogSize : SettingsDefaults.maxLogFileSize
        self.enableLogging = defaults.object(forKey: SettingsKey.enableLogging) as? Bool ?? SettingsDefaults.enableLogging
    }
}

// MARK: - Keychain Helper

/// Secure storage for sensitive values like API keys.
///
/// **Primary**: macOS Keychain (most secure, but access is tied to the
/// code signing identity — ad-hoc "Sign to Run Locally" creates a new
/// identity on every build, making previously saved items inaccessible).
///
/// **Fallback**: A file in `~/Library/Application Support/Bolo/` with
/// restricted file permissions (owner-only read/write). This survives
/// Xcode rebuilds during development. In production with proper code
/// signing, the Keychain will work consistently.
enum KeychainHelper {

    private static let service = "com.bolo.app"

    static func save(_ value: String, for key: String) {
        // Always save to the fallback file (survives code signing changes)
        FallbackStore.save(value, for: key)

        guard let data = value.data(using: .utf8) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Only add if value is not empty
        guard !value.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(_ key: String) -> String? {
        // Try Keychain first (most secure)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
            return value
        }

        // Keychain failed (likely code signing change) — try fallback file
        return FallbackStore.load(key)
    }

    static func delete(_ key: String) {
        FallbackStore.delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Fallback File Store

/// Stores sensitive values in a file within Application Support
/// with owner-only (0600) file permissions. Used as a fallback when
/// the Keychain is inaccessible due to code signing identity changes
/// during development.
private enum FallbackStore {

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bolo", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        storeURL.appendingPathComponent(".\(key).dat")
    }

    static func save(_ value: String, for key: String) {
        let fm = FileManager.default
        let dir = storeURL

        // Create directory if needed with restricted permissions
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }

        let url = fileURL(for: key)

        if value.isEmpty {
            try? fm.removeItem(at: url)
            return
        }

        // Simple obfuscation (base64) — not encryption, just prevents
        // casual viewing. Real security comes from file permissions and
        // the Keychain in production builds.
        guard let data = value.data(using: .utf8) else { return }
        let encoded = data.base64EncodedData()

        fm.createFile(atPath: url.path, contents: encoded, attributes: [
            .posixPermissions: 0o600  // Owner read/write only
        ])
    }

    static func load(_ key: String) -> String? {
        let url = fileURL(for: key)
        guard let encoded = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        let value = String(data: data, encoding: .utf8)
        return (value?.isEmpty == false) ? value : nil
    }

    static func delete(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }
}
