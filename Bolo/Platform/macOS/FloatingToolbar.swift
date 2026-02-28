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
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 60),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: contentView)
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.delegate = self

        // Load saved position or center at top of screen
        if let x = UserDefaults.standard.object(forKey: "FloatingToolbar.x") as? CGFloat,
           let y = UserDefaults.standard.object(forKey: "FloatingToolbar.y") as? CGFloat {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 110
            let y = screenFrame.maxY - 80
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

// MARK: - Floating Toolbar View

/// SwiftUI view for the floating recording indicator toolbar.
struct FloatingToolbarView: View {

    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Recording indicator dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 12, height: 12)
                .scaleEffect(appState.isRecording ? pulseScale : 1.0)
                .animation(
                    appState.isRecording
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: appState.isRecording
                )

            // Status text
            Text(appState.statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            // Audio level indicator (visible when recording)
            if appState.isRecording {
                AudioLevelView(level: appState.audioLevel)
                    .frame(width: 40, height: 20)
            }

            // Processing spinner
            if appState.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var indicatorColor: Color {
        switch appState.state {
        case .idle:
            return appState.isLongTalkActive ? .orange : .gray
        case .recording(let mode):
            return mode == .command ? .purple : .red
        case .processing:
            return .yellow
        case .inserting:
            return .green
        case .error:
            return .red
        }
    }

    private var pulseScale: CGFloat {
        1.0 + CGFloat(appState.audioLevel) * 0.3
    }
}

// MARK: - Audio Level Visualizer

/// Animated bar chart showing real-time audio levels.
struct AudioLevelView: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(for: i))
                        .frame(
                            width: 4,
                            height: barHeight(for: i, in: geometry.size.height)
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func barHeight(for index: Int, in maxHeight: CGFloat) -> CGFloat {
        let threshold = Float(index) * 0.2
        let intensity = max(0, level - threshold) / 0.2
        return max(4, CGFloat(min(intensity, 1.0)) * maxHeight)
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) * 0.2
        return level > threshold ? .green : .gray.opacity(0.3)
    }
}
