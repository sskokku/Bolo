import AVFoundation
import Foundation

// MARK: - Audio Capture Delegate

/// Delegate protocol for receiving audio capture events.
protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidReceiveBuffer(_ pcmData: Data)
    func audioCaptureDidUpdateLevel(_ level: Float)
    func audioCaptureDidFail(_ error: Error)
}

// MARK: - macOS Audio Capture

/// Captures audio from the microphone using AVAudioEngine.
/// Records in 16kHz mono 16-bit PCM format, optimal for Gemini API speech processing.
class MacOSAudioCapture: @unchecked Sendable {

    weak var delegate: AudioCaptureDelegate?

    private let audioEngine = AVAudioEngine()
    private var pcmBuffer = Data()
    private let sampleRate: Double = 16000
    private let channelCount: AVAudioChannelCount = 1

    var isRecording: Bool {
        audioEngine.isRunning
    }

    // MARK: - Recording Control

    /// Start capturing audio from the default input device.
    /// Audio is accumulated in an internal buffer until `stopRecording()` is called.
    func startRecording() throws {
        // Reset buffer
        pcmBuffer = Data()

        let inputNode = audioEngine.inputNode

        // Get the hardware input format
        let hardwareFormat = inputNode.inputFormat(forBus: 0)

        // Create desired recording format: 16kHz, mono, 16-bit signed integer PCM
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioCapture", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create recording format"
            ])
        }

        // Install a tap on the input node to capture audio buffers.
        // If the hardware format differs from our desired format, AVAudioEngine
        // handles the conversion automatically.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stop capturing audio and return the recorded data as a WAV file.
    /// - Returns: WAV-formatted audio data ready for the Gemini API
    func stopRecording() -> Data {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        let capturedPCM = pcmBuffer
        pcmBuffer = Data()

        // Convert raw PCM to WAV format
        return AudioProcessor.pcmToWAV(
            pcmData: capturedPCM,
            sampleRate: Int(sampleRate),
            channels: Int(channelCount),
            bitsPerSample: 16
        )
    }

    // MARK: - Buffer Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let int16Data = buffer.int16ChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelData = int16Data[0]

        // Calculate RMS audio level for UI visualization
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = Float(channelData[i]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = sqrt(sum / max(Float(frameCount), 1))
        let levelDb = 20 * log10(max(rms, 0.0001))
        // Normalize to 0-1 range (assuming -60dB to 0dB range)
        let normalizedLevel = max(0, min(1, (levelDb + 60) / 60))

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidUpdateLevel(normalizedLevel)
        }

        // Append PCM data to buffer
        let data = Data(bytes: channelData, count: frameCount * MemoryLayout<Int16>.size)
        pcmBuffer.append(data)
    }

    // MARK: - Permissions

    /// Request microphone access from the user.
    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Check if microphone access has been granted.
    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
