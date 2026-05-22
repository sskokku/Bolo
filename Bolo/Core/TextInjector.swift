//
//  TextInjector.swift
//  Bolo
//
//  Synthesizes ⌘V into the frontmost app after placing text on the clipboard.
//  Requires Accessibility permission.
//

import AppKit
import Carbon.HIToolbox

enum TextInjector {
    @MainActor
    static func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let priorSnapshot = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        sendCommandV()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            restore(snapshot: priorSnapshot, to: pasteboard)
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(snapshot: [NSPasteboardItem], to pb: NSPasteboard) {
        pb.clearContents()
        if !snapshot.isEmpty {
            pb.writeObjects(snapshot)
        }
    }
}
