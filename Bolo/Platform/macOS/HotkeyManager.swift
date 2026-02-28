import Carbon
import Cocoa
import os.log

/// Logger for hotkey events — visible in Console.app under "com.bolo.app / HotkeyManager".
private let logger = Logger(subsystem: "com.bolo.app", category: "HotkeyManager")

/// Manages global hotkey detection for Push-to-Talk and Long-Talk modes.
///
/// Uses a CGEvent tap to intercept keyboard events system-wide.
/// Default hotkeys match WhisprFlow conventions:
/// - `fn` (hold) → Push-to-Talk
/// - `fn + Space` → Toggle Long-Talk mode
///
/// Requires Accessibility permission (System Settings → Privacy & Security → Accessibility).
class MacOSHotkeyManager: @unchecked Sendable {

    // MARK: - Callbacks

    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkEnd: (() -> Void)?
    var onLongTalkToggle: (() -> Void)?

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnPressed = false
    private var isSpacePressed = false
    private var isLongTalkActive = false
    private var pushToTalkStartTime: Date?

    // MARK: - Lifecycle

    /// Start listening for global hotkey events.
    /// - Returns: `true` if the event tap was created successfully
    func start() -> Bool {
        logger.info("Starting hotkey manager — AXIsProcessTrusted: \(AXIsProcessTrusted())")

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
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create CGEvent tap — check Accessibility permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        logger.info("Event tap created and enabled successfully")
        return true
    }

    /// Stop listening for hotkey events and clean up resources.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }

    // MARK: - Event Handling

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {

        // Re-enable the tap if it gets disabled by the system
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("Event tap disabled by system (timeout/user) — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        // Handle fn key (modifier flags changed)
        if type == .flagsChanged {
            let flags = event.flags
            let fnPressed = flags.contains(.maskSecondaryFn)

            if fnPressed != isFnPressed {
                isFnPressed = fnPressed
                logger.info("fn key \(fnPressed ? "PRESSED" : "RELEASED") — longTalkActive: \(self.isLongTalkActive)")

                if !isLongTalkActive {
                    if fnPressed {
                        pushToTalkStartTime = Date()
                        DispatchQueue.main.async { [weak self] in
                            logger.info("Calling onPushToTalkStart")
                            self?.onPushToTalkStart?()
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            logger.info("Calling onPushToTalkEnd")
                            self?.onPushToTalkEnd?()
                        }
                    }
                } else if !fnPressed {
                    // In long-talk mode, fn release stops it
                    isLongTalkActive = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onLongTalkToggle?()
                    }
                }
            }
        }

        // Handle Space key for Long-Talk toggle (fn + Space)
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Space = keycode 49
            if keyCode == 49 && isFnPressed && !isSpacePressed && !isLongTalkActive {
                isSpacePressed = true
                isLongTalkActive = true
                logger.info("fn+Space detected — toggling Long-Talk")
                DispatchQueue.main.async { [weak self] in
                    self?.onLongTalkToggle?()
                }
                return nil // Consume the event so Space doesn't type
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
