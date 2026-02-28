import SwiftUI
import AppKit

// MARK: - Floating Toolbar Controller

/// Manages a floating panel window that shows the recording indicator.
/// The panel floats above all windows, is draggable, and shows on all Spaces.
/// Persists its position via UserDefaults so it restores on relaunch.
class FloatingToolbarController: NSObject, NSWindowDelegate {

    private var window: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupWindow()
    }

    private func setupWindow() {
        let contentView = FloatingToolbarView(appState: appState)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // Views handle their own shadow
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.delegate = self

        // Migrate old position: if saved at top, reset to bottom-center
        let savedVersion = UserDefaults.standard.string(forKey: "FloatingToolbar.version")
        if savedVersion != "v2" {
            UserDefaults.standard.removeObject(forKey: "FloatingToolbar.x")
            UserDefaults.standard.removeObject(forKey: "FloatingToolbar.y")
            UserDefaults.standard.set("v2", forKey: "FloatingToolbar.version")
        }

        // Load saved position or center at bottom of screen
        if let x = UserDefaults.standard.object(forKey: "FloatingToolbar.x") as? CGFloat,
           let y = UserDefaults.standard.object(forKey: "FloatingToolbar.y") as? CGFloat {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 210 // center a 420px window
            let y = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window = panel
    }

    func show() {
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// Save the toolbar position whenever the user drags it to a new location.
    func windowDidMove(_ notification: Notification) {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: "FloatingToolbar.x")
        UserDefaults.standard.set(origin.y, forKey: "FloatingToolbar.y")
    }
}

// MARK: - Main Floating Toolbar View

/// WhisprFlow-inspired pill-shaped floating recording indicator.
/// Changes size and color based on recording state with smooth spring animations.
struct FloatingToolbarView: View {

    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            pillContent
        }
        .frame(width: 420, height: 80, alignment: .center)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: appState.state)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch appState.state {
        case .idle:
            IdlePillView(isLongTalkActive: appState.isLongTalkActive)
                .transition(.blurReplace)
        case .recording(let mode):
            RecordingPillView(
                mode: mode,
                duration: appState.recordingDuration,
                waveformSamples: appState.waveformSamples
            )
            .transition(.blurReplace)
        case .processing:
            ProcessingPillView()
                .transition(.blurReplace)
        case .inserting:
            SuccessPillView()
                .transition(.blurReplace)
        case .error(let error):
            ErrorPillView(error: error)
                .transition(.blurReplace)
        }
    }
}

// MARK: - Idle Pill

struct IdlePillView: View {
    let isLongTalkActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isLongTalkActive ? Color.orange : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)

            Text(isLongTalkActive ? "Long-Talk" : "Ready")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
    }
}

// MARK: - Recording Pill

struct RecordingPillView: View {
    let mode: RecordingMode
    let duration: TimeInterval
    let waveformSamples: [Float]

    var body: some View {
        HStack(spacing: 14) {
            PulsingDot()

            WaveformView(samples: waveformSamples)
                .frame(width: 160, height: 28)

            Text(formatDuration(duration))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())

            Text(modeLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(.white.opacity(0.15))
                }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Color.red.opacity(0.15))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.red.opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .red.opacity(0.2), radius: 12, y: 4)
        }
    }

    private var modeLabel: String {
        switch mode {
        case .pushToTalk: return "PTT"
        case .longTalk: return "LONG"
        case .command: return "CMD"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Processing Pill

struct ProcessingPillView: View {
    var body: some View {
        HStack(spacing: 12) {
            ShimmerDotsView()

            Text("Transcribing...")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Color.blue.opacity(0.12))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.blue.opacity(0.25), lineWidth: 0.5)
                }
                .shadow(color: .blue.opacity(0.15), radius: 10, y: 4)
        }
    }
}

// MARK: - Success Pill

struct SuccessPillView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: true)

            Text("Done")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Color.green.opacity(0.15))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.green.opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .green.opacity(0.15), radius: 10, y: 4)
        }
    }
}

// MARK: - Error Pill

struct ErrorPillView: View {
    let error: AppError

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)

            Text(shortMessage)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(Color.red.opacity(0.25))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 0.5)
                }
                .shadow(color: .red.opacity(0.2), radius: 10, y: 4)
        }
    }

    private var shortMessage: String {
        switch error {
        case .microphonePermissionDenied: return "Microphone access required"
        case .accessibilityPermissionDenied: return "Accessibility access required"
        case .apiKeyMissing: return "API key not configured"
        case .apiError(let msg): return "Error: \(msg.prefix(30))"
        case .networkError: return "Network error"
        case .audioTooShort: return "Recording too short"
        case .audioTooLong: return "Recording too long"
        case .insertionFailed: return "Insertion failed"
        case .noFocusedTextField: return "No text field focused"
        case .protectedField: return "Cannot dictate into password fields"
        }
    }
}

// MARK: - Pulsing Dot

/// Animated red recording dot with a pulsing ring.
struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Outer pulsing ring
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 18, height: 18)
                .scaleEffect(isPulsing ? 1.4 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.6)

            // Inner solid dot
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.0)
                .repeatForever(autoreverses: false)
            ) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Waveform View

/// Canvas-based 24-bar audio waveform visualization.
/// Each bar is a rounded rectangle driven by the rolling waveformSamples buffer.
struct WaveformView: View {
    let samples: [Float]

    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2.5
    private let cornerRadius: CGFloat = 1.5
    private let minBarHeight: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let barCount = samples.count
            let totalBarWidth = barWidth + barSpacing
            let startX = (size.width - CGFloat(barCount) * totalBarWidth + barSpacing) / 2

            for i in 0..<barCount {
                let sample = CGFloat(samples[i])
                let height = max(minBarHeight, sample * (size.height - 2))
                let x = startX + CGFloat(i) * totalBarWidth
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

                // Bars fade from slightly transparent at the left to fully white on the right
                let opacity = 0.5 + 0.5 * (Double(i) / Double(barCount - 1))
                context.fill(path, with: .color(.white.opacity(opacity)))
            }
        }
        .animation(.linear(duration: 0.08), value: samples)
    }
}

// MARK: - Shimmer Dots

/// Three dots that cycle sequentially for the processing state.
struct ShimmerDotsView: View {

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                        .opacity(dotOpacity(index: i, phase: phase))
                        .scaleEffect(dotScale(index: i, phase: phase))
                }
            }
        }
    }

    private func dotOpacity(index: Int, phase: Double) -> Double {
        let cycle = phase.truncatingRemainder(dividingBy: 1.2)
        let dotStart = Double(index) * 0.3
        let progress = (cycle - dotStart).truncatingRemainder(dividingBy: 1.2)
        if progress >= 0 && progress < 0.4 {
            return 0.4 + 0.6 * sin(progress / 0.4 * .pi)
        }
        return 0.4
    }

    private func dotScale(index: Int, phase: Double) -> Double {
        let cycle = phase.truncatingRemainder(dividingBy: 1.2)
        let dotStart = Double(index) * 0.3
        let progress = (cycle - dotStart).truncatingRemainder(dividingBy: 1.2)
        if progress >= 0 && progress < 0.4 {
            return 0.85 + 0.3 * sin(progress / 0.4 * .pi)
        }
        return 0.85
    }
}
