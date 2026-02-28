import ApplicationServices
import Cocoa

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
    /// Tries direct AX insertion first, falls back to clipboard paste.
    func insertText(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw InsertionError.accessibilityDenied
        }

        if let element = getFocusedElement() {
            // Check for password fields
            if isPasswordField(element) {
                throw InsertionError.passwordField
            }

            // Try direct AX insertion
            if tryDirectInsertion(element: element, text: text) {
                return
            }
        }

        // Fallback to clipboard-based insertion
        insertViaClipboard(text)
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
    func replaceSelectedText(with text: String) throws {
        guard let element = getFocusedElement() else {
            throw InsertionError.noFocusedElement
        }

        if isPasswordField(element) {
            throw InsertionError.passwordField
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if result != .success {
            // Fallback: use clipboard
            insertViaClipboard(text)
        }
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
        AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )

        if let rangeValue = selectedRange as! AXValue? {
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

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedApp as! AXUIElement,
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

    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let previousContents = pasteboard.string(forType: .string)

        // Set our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V paste
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Restore original clipboard after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }
}
