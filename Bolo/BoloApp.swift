//
//  BoloApp.swift
//  Bolo
//

import SwiftUI
import AppKit
import ApplicationServices
import SwiftData

@main
struct BoloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dictation = DictationController.shared
    @State private var stats = UsageStats.shared

    private var menuBarSymbol: String {
        if dictation.isRecording { return "waveform" }
        #if DEBUG
        return "ladybug.fill"
        #else
        return "quote.bubble.fill"
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(dictation)
                .environment(stats)
                .modelContainer(DictationController.shared.modelContainer)
        } label: {
            Image(systemName: menuBarSymbol)
                .symbolRenderingMode(.monochrome)
                .symbolEffect(.variableColor.iterative.reversing,
                              options: .repeating,
                              isActive: dictation.isRecording)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(dictation)
                .environment(stats)
                .modelContainer(DictationController.shared.modelContainer)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            HotkeyMonitor.promptForAccessibility()
        }
        hotkey.start(
            onPress: {
                Task { @MainActor in await DictationController.shared.pttPress() }
            },
            onRelease: {
                Task { @MainActor in await DictationController.shared.pttRelease() }
            }
        )
    }
}
