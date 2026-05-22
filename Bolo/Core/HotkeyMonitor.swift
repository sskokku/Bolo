//
//  HotkeyMonitor.swift
//  Bolo
//
//  Push-to-talk on ⌃⇧ hold. Requires Accessibility permission.
//

import AppKit
import ApplicationServices

final class HotkeyMonitor {
    private var monitor: Any?
    private var wasHeld = false

    func start(
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        stop()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let required: NSEvent.ModifierFlags = [.control, .shift]
            let isHeld = (flags == required)
            guard isHeld != self.wasHeld else { return }
            self.wasHeld = isHeld
            let press = isHeld
            Task { @MainActor in
                if press { onPress() } else { onRelease() }
            }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
