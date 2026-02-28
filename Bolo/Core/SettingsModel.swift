import Foundation
import Security
import ServiceManagement

// MARK: - Settings Keys

/// UserDefaults keys for app preferences.
enum SettingsKey {
    static let apiKey = "gemini_api_key"
    static let model = "gemini_model"
    static let pushToTalkKey = "hotkey_push_to_talk"
    static let longTalkKey = "hotkey_long_talk"
    static let showFloatingToolbar = "show_floating_toolbar"
    static let autoLearnDictionary = "auto_learn_dictionary"
    static let maxRecordingDuration = "max_recording_duration"
    static let enableCommandMode = "enable_command_mode"
    static let hasCompletedOnboarding = "has_completed_onboarding"
    static let launchAtLogin = "launch_at_login"
}

// MARK: - Settings Defaults

/// Default values for all settings.
enum SettingsDefaults {
    static let model = "gemini-2.5-flash"
    static let pushToTalkKey = "fn"
    static let longTalkKey = "fn+space"
    static let showFloatingToolbar = true
    static let autoLearnDictionary = true
    static let maxRecordingDuration: TimeInterval = 300 // 5 minutes
    static let enableCommandMode = true
    static let hasCompletedOnboarding = false
    static let launchAtLogin = false
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

    @Published var showFloatingToolbar: Bool {
        didSet { UserDefaults.standard.set(showFloatingToolbar, forKey: SettingsKey.showFloatingToolbar) }
    }

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
            print("[Bolo] Failed to update launch-at-login: \(error)")
        }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard
        self.apiKey = KeychainHelper.load(SettingsKey.apiKey) ?? ""
        self.model = defaults.string(forKey: SettingsKey.model) ?? SettingsDefaults.model
        self.showFloatingToolbar = defaults.object(forKey: SettingsKey.showFloatingToolbar) as? Bool ?? SettingsDefaults.showFloatingToolbar
        self.autoLearnDictionary = defaults.object(forKey: SettingsKey.autoLearnDictionary) as? Bool ?? SettingsDefaults.autoLearnDictionary
        self.maxRecordingDuration = defaults.object(forKey: SettingsKey.maxRecordingDuration) as? TimeInterval ?? SettingsDefaults.maxRecordingDuration
        self.enableCommandMode = defaults.object(forKey: SettingsKey.enableCommandMode) as? Bool ?? SettingsDefaults.enableCommandMode
        self.hasCompletedOnboarding = defaults.bool(forKey: SettingsKey.hasCompletedOnboarding)
        self.launchAtLogin = defaults.bool(forKey: SettingsKey.launchAtLogin)
    }
}

// MARK: - Keychain Helper

/// Secure storage for sensitive values like API keys.
enum KeychainHelper {

    private static let service = "com.bolo.app"

    static func save(_ value: String, for key: String) {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
