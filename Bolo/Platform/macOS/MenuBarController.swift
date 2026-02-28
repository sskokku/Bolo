import SwiftUI
import AppKit

/// Manages the NSStatusItem (menu bar icon) and its dropdown menu.
/// Updates the icon to reflect the current app state (idle, recording, processing, error).
///
/// Since Bolo is an LSUIElement app (no Dock icon, no standard app menu),
/// we manage settings/dictionary/history windows ourselves using NSWindow.
@MainActor
class MenuBarController: ObservableObject {

    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var settingsWindow: NSWindow?
    private var dictionaryWindow: NSWindow?
    private var historyWindow: NSWindow?

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

        let historyItem = NSMenuItem(title: "History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

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

    // MARK: - Public Window Access

    /// Open the settings window programmatically (e.g., when API key is missing).
    func openSettingsWindow() {
        openSettings()
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bolo Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc private func openDictionary() {
        if let window = dictionaryWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let dictionaryView = DictionaryView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bolo Dictionary"
        window.contentView = NSHostingView(rootView: dictionaryView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        dictionaryWindow = window
    }

    @objc private func openHistory() {
        if let window = historyWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let historyView = HistoryView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bolo History"
        window.contentView = NSHostingView(rootView: historyView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        historyWindow = window
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openDictionary = Notification.Name("com.bolo.openDictionary")
}
