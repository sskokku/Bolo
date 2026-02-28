import SwiftUI
import AppKit

/// Manages the NSStatusItem (menu bar icon) and its dropdown menu.
/// Updates the icon to reflect the current app state (idle, recording, processing, error).
@MainActor
class MenuBarController: ObservableObject {

    private var statusItem: NSStatusItem!
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Bolo")
            button.image?.isTemplate = true
        }

        // Build the dropdown menu
        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(title: "Bolo — Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenuItem.tag = 100 // Tag for updating status text
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let dictionaryItem = NSMenuItem(title: "Dictionary...", action: #selector(openDictionary), keyEquivalent: "d")
        dictionaryItem.target = self
        menu.addItem(dictionaryItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Bolo", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Bolo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Icon Updates

    /// Update the menu bar icon to reflect the current app state.
    func updateIcon(for state: RecordingState) {
        let symbolName: String
        switch state {
        case .idle:
            symbolName = "mic.fill"
        case .recording:
            symbolName = "mic.circle.fill"
        case .processing:
            symbolName = "ellipsis.circle.fill"
        case .inserting:
            symbolName = "checkmark.circle.fill"
        case .error:
            symbolName = "exclamationmark.triangle.fill"
        }

        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Bolo"
        )
        statusItem.button?.image?.isTemplate = (state == .idle)

        // Update status text in menu
        if let menu = statusItem.menu,
           let statusItem = menu.item(withTag: 100) {
            statusItem.title = "Bolo — \(appState.statusText)"
        }
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDictionary() {
        // Post notification that DictionaryView can observe
        NotificationCenter.default.post(name: .openDictionary, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openDictionary = Notification.Name("com.bolo.openDictionary")
}
