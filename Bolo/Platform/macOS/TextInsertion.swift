import ApplicationServices
import Cocoa
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "TextInsertion")

/// Handles inserting transcribed text into the active application's text field.
///
/// Uses the macOS Accessibility API (AXUIElement) for direct text insertion,
/// with a clipboard-based fallback for apps that don't support direct AX insertion.
class MacOSTextInsertion {

    // MARK: - Errors

    enum InsertionError: Error, LocalizedError {
        case noFocusedElement
        case notTextField
        case passwordField
        case insertionFailed
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .noFocusedElement: return "No focused text element found"
            case .notTextField: return "Focused element is not a text field"
            case .passwordField: return "Cannot insert into password fields"
            case .insertionFailed: return "Text insertion failed"
            case .accessibilityDenied: return "Accessibility permission required"
            }
        }
    }

    // MARK: - Insert Text

    /// Insert text at the cursor position in the frontmost app.
    ///
    /// When a `targetPID` is provided, always uses clipboard + Cmd+V posted
    /// directly to that process.  This is the most reliable method and works
    /// in every app (native, Electron, browsers).  AX direct insertion is only
    /// attempted as a last resort when no target PID is available, because
    /// Electron/browser apps report AX success without actually inserting text.
    ///
    /// - Parameters:
    ///   - text: The text to insert
    ///   - targetPID: Optional PID of the target app for direct event delivery
    func insertText(_ text: String, targetPID: pid_t? = nil) throws {
        let trusted = AXIsProcessTrusted()
        logger.info("insertText called — AXIsProcessTrusted: \(trusted), text length: \(text.count), targetPID: \(targetPID.map { String($0) } ?? "nil")")

        // When we have a target PID, ALWAYS use clipboard paste.
        // AX insertion reports false success for Electron/browser apps
        // (e.g. Claude, Chrome, VS Code, Slack) — the API returns .success
        // but the text never appears.  Clipboard + postToPid is universal.
        if let pid = targetPID, trusted {
            logger.info("Using clipboard + postToPid for targeted insertion (PID \(pid))")
            insertViaClipboard(text, targetPID: pid)
            return
        }

        // No target PID — try AX-based insertion as fallback
        if trusted, let element = getFocusedElement() {
            if isPasswordField(element) {
                throw InsertionError.passwordField
            }

            if tryDirectInsertion(element: element, text: text) {
                logger.info("Text inserted via AX API (no target PID path)")
                return
            }
            logger.warning("AX direct insertion failed — falling back to clipboard")
        } else {
            logger.info("AX not available (trusted: \(trusted)) — using clipboard fallback")
        }

        // Last resort: clipboard with no target PID (broadcasts to HID tap)
        insertViaClipboard(text, targetPID: targetPID)
    }

    // MARK: - Selection (for Command Mode)

    /// Get the currently selected text in the focused element.
    /// Returns nil if no text is selected or no element is focused.
    func getSelectedText() -> String? {
        guard let element = getFocusedElement() else { return nil }

        var selectedText: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        guard result == .success, let text = selectedText as? String, !text.isEmpty else {
            return nil
        }

        return text
    }

    /// Replace the currently selected text with new text.
    /// Uses clipboard paste when a target PID is provided (most reliable).
    /// - Parameters:
    ///   - text: The replacement text
    ///   - targetPID: Optional PID of the target app for direct event delivery
    func replaceSelectedText(with text: String, targetPID: pid_t? = nil) throws {
        let trusted = AXIsProcessTrusted()
        logger.info("replaceSelectedText called — AXIsProcessTrusted: \(trusted)")

        // When we have a target PID, always use clipboard paste (see insertText for rationale)
        if let pid = targetPID, trusted {
            logger.info("Using clipboard + postToPid for targeted replacement (PID \(pid))")
            insertViaClipboard(text, targetPID: pid)
            return
        }

        // No target PID — try AX-based replacement
        if trusted, let element = getFocusedElement() {
            if isPasswordField(element) {
                throw InsertionError.passwordField
            }

            let result = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )

            if result == .success {
                logger.info("Text replaced via AX API")
                return
            }
            logger.warning("AX replacement failed — falling back to clipboard")
        }

        // Last resort: clipboard with no target PID
        insertViaClipboard(text, targetPID: targetPID)
    }

    // MARK: - Context Extraction

    /// Get surrounding text context from the focused text field.
    /// This context is sent to Gemini for formatting-aware transcription.
    func getTextContext(maxLength: Int = 500) -> String? {
        guard let element = getFocusedElement() else { return nil }

        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        )

        guard result == .success, let fullText = value as? String, !fullText.isEmpty else {
            return nil
        }

        // Get cursor position via selected text range
        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        if rangeResult == .success, let rangeObj = selectedRange {
            let rangeValue = rangeObj as! AXValue
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                // Extract context around cursor position
                let start = max(0, cfRange.location - maxLength / 2)
                let end = min(fullText.count, cfRange.location + maxLength / 2)

                let nsString = fullText as NSString
                let safeStart = min(start, nsString.length)
                let safeEnd = min(end, nsString.length)
                let safeLength = max(0, safeEnd - safeStart)

                return nsString.substring(with: NSRange(location: safeStart, length: safeLength))
            }
        }

        // Return last N characters if no cursor position found
        return String(fullText.suffix(maxLength))
    }

    /// Detect the active application for context-aware formatting.
    func getActiveAppContext() -> String? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleId = frontmostApp.bundleIdentifier ?? ""
        let appName = frontmostApp.localizedName ?? ""

        // Categorize app for context
        let category: String
        switch bundleId {
        case let id where id.contains("mail") || id.contains("Mail") || id.contains("Gmail") || id.contains("Outlook"):
            category = "email"
        case let id where id.contains("slack") || id.contains("Discord") || id.contains("telegram") || id.contains("Messages") || id.contains("WhatsApp"):
            category = "messaging"
        case let id where id.contains("Xcode") || id.contains("VSCode") || id.contains("cursor") || id.contains("Cursor"):
            category = "code"
        case let id where id.contains("TextEdit") || id.contains("Word") || id.contains("obsidian") || id.contains("Notion") || id.contains("Docs"):
            category = "document"
        default:
            category = "general"
        }

        return "App: \(appName) (\(category))"
    }

    // MARK: - Private: AX Helpers

    private func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        ) == .success else {
            return nil
        }

        // AXUIElementCopyAttributeValue returns AXUIElement as AnyObject on success.
        // The cast is safe here because the Accessibility API guarantees the type.
        let appElement = focusedApp as! AXUIElement

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    private func isPasswordField(_ element: AXUIElement) -> Bool {
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)

        if let subroleString = subrole as? String {
            return subroleString == (kAXSecureTextFieldSubrole as String)
        }
        return false
    }

    private func tryDirectInsertion(element: AXUIElement, text: String) -> Bool {
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    // MARK: - Private: Clipboard Fallback

    private func insertViaClipboard(_ text: String, targetPID: pid_t? = nil) {
        logger.info("insertViaClipboard — targetPID: \(targetPID.map { String($0) } ?? "nil")")

        // Ensure text is on clipboard (caller should have set it, but be safe)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Wait for the pasteboard to be ready and the target app to have focus
        usleep(100_000) // 100ms

        // Simulate Cmd+V paste via CGEvent
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            logger.error("Failed to create CGEvent for Cmd+V")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let pid = targetPID {
            // Send Cmd+V directly to the target process — much more reliable
            // than posting to the HID tap, especially for Electron/browser apps.
            logger.info("Posting Cmd+V directly to PID \(pid)")
            keyDown.postToPid(pid)
            usleep(30_000) // 30ms between key down and key up
            keyUp.postToPid(pid)
        } else {
            // No target PID — broadcast to the HID event tap (less reliable)
            logger.info("Posting Cmd+V to HID event tap (no target PID)")
            keyDown.post(tap: .cghidEventTap)
            usleep(30_000) // 30ms
            keyUp.post(tap: .cghidEventTap)
        }

        logger.info("Cmd+V paste event posted — text remains on clipboard for manual paste")

        // NOTE: We intentionally do NOT restore the old clipboard contents.
        // The transcribed text stays on the clipboard so the user can
        // manually Cmd+V if the simulated paste didn't reach the right app.
    }
}
