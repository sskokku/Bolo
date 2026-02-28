import Carbon
import Cocoa
import os.log

/// Logger for hotkey events — visible in Console.app under "com.bolo.app / HotkeyManager".
private let logger = Logger(subsystem: "com.bolo.app", category: "HotkeyManager")

/// Manages global hotkey detection for Push-to-Talk and Long-Talk modes.
///
/// **Strategy**:  Tries to install a CGEvent tap first (allows consuming events
/// like Ctrl+Shift+Space so Space doesn't leak through).  If that fails
/// — typically because Accessibility permission hasn't been granted yet —
/// falls back to `NSEvent.addGlobalMonitorForEvents` which still works for
/// modifier-only hotkeys without needing to consume events.
///
/// Hotkeys:
/// - `Ctrl+Shift` (hold both) → Push-to-Talk (record while held, transcribe on release)
/// - `Ctrl+Shift+Space` → Toggle Long-Talk mode (press to start/stop)
///
/// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility).
class MacOSHotkeyManager: @unchecked Sendable {

    // MARK: - Callbacks

    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkEnd: (() -> Void)?
    var onLongTalkToggle: (() -> Void)?

    // MARK: - Private State

    /// CGEvent tap (primary, if available)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// NSEvent global monitors (fallback)
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    /// Which mechanism is active
    private(set) var usingEventTap = false
    private(set) var usingNSEventMonitor = false

    /// Tracks whether Ctrl+Shift are currently held together.
    private var isHotkeyHeld = false
    private var isSpacePressed = false
    private var isLongTalkActive = false
    private var pushToTalkStartTime: Date?

    /// The modifier combo we listen for: Control + Shift (no other modifiers).
    private let requiredModifiers: CGEventFlags = [.maskControl, .maskShift]
    private let requiredNSModifiers: NSEvent.ModifierFlags = [.control, .shift]

    /// Mask of all modifier keys we care about (to exclude Cmd, Option, etc.).
    private let allModifiersMask: CGEventFlags = [.maskControl, .maskShift, .maskCommand, .maskAlternate]
    private let allNSModifiersMask: NSEvent.ModifierFlags = [.control, .shift, .command, .option]

    // MARK: - Lifecycle

    /// Start listening for global hotkey events.
    ///
    /// Tries CGEvent tap first (best: can consume events).
    /// Falls back to NSEvent global monitors if the tap fails.
    ///
    /// - Returns: `true` if at least one mechanism started successfully.
    func start() -> Bool {
        let trusted = AXIsProcessTrusted()
        logger.info("Starting hotkey manager — AXIsProcessTrusted: \(trusted)")

        // --- Attempt 1: CGEvent tap (requires Accessibility) ---
        if startEventTap() {
            usingEventTap = true
            logger.info("Using CGEvent tap (primary)")
            return true
        }

        // --- Attempt 2: NSEvent global monitors (fallback) ---
        logger.warning("CGEvent tap failed — falling back to NSEvent global monitors")

        if startNSEventMonitors() {
            usingNSEventMonitor = true
            logger.info("Using NSEvent global monitors (fallback)")
            return true
        }

        logger.error("Both CGEvent tap and NSEvent monitors failed — hotkeys unavailable")
        ErrorLogger.shared.logError(category: .hotkey, message: "Both CGEvent tap and NSEvent monitors failed — hotkeys unavailable")
        return false
    }

    /// Stop listening for hotkey events and clean up all resources.
    func stop() {
        stopEventTap()
        stopNSEventMonitors()
    }

    deinit {
        stop()
    }

    // MARK: - CGEvent Tap (Primary)

    private func startEventTap() -> Bool {
        let eventMask: CGEventMask = (
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passRetained(event)
                }
                let manager = Unmanaged<MacOSHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create CGEvent tap — Accessibility permission likely missing")
            ErrorLogger.shared.logWarning(category: .hotkey, message: "CGEvent tap creation failed — Accessibility permission likely missing")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("CGEvent tap created and enabled")
        return true
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        usingEventTap = false
    }

    // MARK: - NSEvent Global Monitors (Fallback)

    private func startNSEventMonitors() -> Bool {
        // Monitor modifier key changes (flagsChanged)
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleNSFlagsChanged(event)
        }

        // Monitor key down (for Ctrl+Shift+Space)
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleNSKeyDown(event)
        }

        // Monitor key up (for Space release tracking)
        keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleNSKeyUp(event)
        }

        // NSEvent monitors return nil if they fail, but typically they succeed
        // even without Accessibility for modifier events. Check if at least
        // the flags monitor was created.
        if flagsMonitor != nil {
            logger.info("NSEvent global monitors installed")
            return true
        }

        logger.error("Failed to install NSEvent global monitors")
        ErrorLogger.shared.logError(category: .hotkey, message: "Failed to install NSEvent global monitors")
        return false
    }

    private func stopNSEventMonitors() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        if let monitor = keyUpMonitor {
            NSEvent.removeMonitor(monitor)
            keyUpMonitor = nil
        }
        usingNSEventMonitor = false
    }

    // MARK: - CGEvent Handling (Primary Path)

    private func handleCGEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if it gets disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("Event tap disabled by system — re-enabling")
            ErrorLogger.shared.logWarning(category: .hotkey, message: "Event tap disabled by system — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Handle modifier key changes
        if type == .flagsChanged {
            let flags = event.flags
            let relevantFlags = flags.intersection(allModifiersMask)
            let hotkeyHeld = relevantFlags == requiredModifiers

            handleHotkeyStateChange(hotkeyNowHeld: hotkeyHeld)
        }

        // Handle Space key for Long-Talk toggle (Ctrl+Shift+Space)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 && isHotkeyHeld && !isSpacePressed && !isLongTalkActive {
                isSpacePressed = true
                isLongTalkActive = true
                logger.info("Ctrl+Shift+Space detected — toggling Long-Talk")
                DispatchQueue.main.async { [weak self] in
                    self?.onLongTalkToggle?()
                }
                return nil // Consume the Space so it doesn't type
            }
        }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 49 {
                isSpacePressed = false
            }
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - NSEvent Handling (Fallback Path)

    private func handleNSFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(allNSModifiersMask)
        let hotkeyHeld = flags == requiredNSModifiers

        handleHotkeyStateChange(hotkeyNowHeld: hotkeyHeld)
    }

    private func handleNSKeyDown(_ event: NSEvent) {
        // Space = keycode 49
        if event.keyCode == 49 && isHotkeyHeld && !isSpacePressed && !isLongTalkActive {
            isSpacePressed = true
            isLongTalkActive = true
            logger.info("Ctrl+Shift+Space detected (NSEvent) — toggling Long-Talk")
            // Note: NSEvent monitors can't consume events, so Space may leak through
            DispatchQueue.main.async { [weak self] in
                self?.onLongTalkToggle?()
            }
        }
    }

    private func handleNSKeyUp(_ event: NSEvent) {
        if event.keyCode == 49 {
            isSpacePressed = false
        }
    }

    // MARK: - Shared Hotkey Logic

    /// Core hotkey state machine used by both CGEvent and NSEvent paths.
    private func handleHotkeyStateChange(hotkeyNowHeld: Bool) {
        guard hotkeyNowHeld != isHotkeyHeld else { return }

        isHotkeyHeld = hotkeyNowHeld
        logger.info("Ctrl+Shift \(hotkeyNowHeld ? "PRESSED" : "RELEASED") — longTalkActive: \(self.isLongTalkActive)")

        if !isLongTalkActive {
            if hotkeyNowHeld {
                // Ctrl+Shift pressed → start Push-to-Talk recording
                pushToTalkStartTime = Date()
                DispatchQueue.main.async { [weak self] in
                    logger.info("Calling onPushToTalkStart")
                    self?.onPushToTalkStart?()
                }
            } else {
                // Ctrl+Shift released → stop recording and transcribe
                DispatchQueue.main.async { [weak self] in
                    logger.info("Calling onPushToTalkEnd")
                    self?.onPushToTalkEnd?()
                }
            }
        } else if !hotkeyNowHeld {
            // In long-talk mode, releasing Ctrl+Shift stops it
            isLongTalkActive = false
            DispatchQueue.main.async { [weak self] in
                self?.onLongTalkToggle?()
            }
        }
    }

    // MARK: - Retry (upgrade from NSEvent to CGEvent tap)

    /// Call after the user grants Accessibility permission to upgrade
    /// from the NSEvent fallback to the full CGEvent tap.
    func retryEventTap() -> Bool {
        guard !usingEventTap else { return true } // Already using event tap

        if startEventTap() {
            // Successfully upgraded — remove NSEvent monitors
            stopNSEventMonitors()
            usingEventTap = true
            usingNSEventMonitor = false
            logger.info("Upgraded from NSEvent monitors to CGEvent tap")
            return true
        }
        return false
    }

    // MARK: - Permissions

    /// Check if the app has Accessibility permission without prompting.
    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Request Accessibility permission, showing the system prompt.
    static func requestAccessibilityPermission() {
        // kAXTrustedCheckOptionPrompt is "AXTrustedCheckOptionPrompt"
        // Using the string directly avoids Swift 6 concurrency warnings
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
