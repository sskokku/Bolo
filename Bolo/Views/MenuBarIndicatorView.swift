import SwiftUI

/// Compact live indicator for the macOS menu bar (~22px tall, variable width).
/// Shows different content per RecordingState with smooth animations.
/// Embedded in the NSStatusItem button via NSHostingView by MenuBarController.
struct MenuBarIndicatorView: View {

    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.state {
            case .idle:
                idleContent
            case .recording(let mode):
                recordingContent(mode: mode)
            case .processing:
                processingContent
            case .inserting:
                insertingContent
            case .error:
                errorContent
            }
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.25), value: appState.state)
    }

    // MARK: - Idle

    private var idleContent: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 14))
            .foregroundStyle(.primary)
    }

    // MARK: - Recording

    private func recordingContent(mode: RecordingMode) -> some View {
        HStack(spacing: 4) {
            // Tiny pulsing red dot
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .modifier(PulseModifier())

            // Mini waveform: downsample 24 bars → 6 bars
            MiniWaveformView(samples: downsampledWaveform)
                .frame(width: 30, height: 14)

            // Duration counter
            Text(formatDuration(appState.recordingDuration))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 4)
    }

    private var downsampledWaveform: [Float] {
        stride(from: 0, to: appState.waveformSamples.count, by: 4).map { i in
            appState.waveformSamples[i]
        }
    }

    // MARK: - Processing

    private var processingContent: some View {
        HStack(spacing: 3) {
            MiniShimmerDots()
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Inserting

    private var insertingContent: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
            Text("Done")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Error

    private var errorContent: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.red)
    }

    // MARK: - Helpers

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Pulse Modifier

/// Simple opacity pulse animation for the recording dot.
struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Self.Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Mini Waveform

/// Compact 6-bar waveform for the menu bar (downsampled from 24-bar buffer).
struct MiniWaveformView: View {
    let samples: [Float]

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.0
    private let cornerRadius: CGFloat = 1.0
    private let minBarHeight: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let barCount = samples.count
            let totalBarWidth = barWidth + barSpacing
            let totalWidth = CGFloat(barCount) * totalBarWidth - barSpacing
            let startX = (size.width - totalWidth) / 2

            for i in 0..<barCount {
                let sample = CGFloat(samples[i])
                let height = max(minBarHeight, sample * (size.height - 2))
                let x = startX + CGFloat(i) * totalBarWidth
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                context.fill(path, with: .color(.red.opacity(0.85)))
            }
        }
        .animation(.linear(duration: 0.08), value: samples)
    }
}

// MARK: - Mini Shimmer Dots

/// Three tiny cycling dots for the processing state in the menu bar.
struct MiniShimmerDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 4, height: 4)
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
