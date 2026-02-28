import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.bolo.app", category: "AudioCapture")

// MARK: - Audio Capture Delegate

/// Delegate protocol for receiving audio capture events.
protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidReceiveBuffer(_ pcmData: Data)
    func audioCaptureDidUpdateLevel(_ level: Float)
    func audioCaptureDidFail(_ error: Error)
}

// MARK: - macOS Audio Capture

/// Captures audio from the microphone using AVAudioEngine.
///
/// Records at the hardware's native format (typically 48 kHz Float32) and
/// converts to 16 kHz mono 16-bit PCM in real-time using AVAudioConverter.
/// The 16 kHz Int16 output is optimal for the Gemini API speech processing.
class MacOSAudioCapture: @unchecked Sendable {

    weak var delegate: AudioCaptureDelegate?

    private let audioEngine = AVAudioEngine()
    private var pcmBuffer = Data()
    private var audioConverter: AVAudioConverter?

    /// Target output format for Gemini API
    private let targetSampleRate: Double = 16000
    private let targetChannelCount: AVAudioChannelCount = 1

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

        // Use the input node's OUTPUT format for the tap.
        // This matches the hardware — AVAudioEngine requires tap format to match.
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Hardware format: \(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) ch, \(hardwareFormat.commonFormat.rawValue) format")

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCapture", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid hardware audio format (sample rate: \(hardwareFormat.sampleRate))"
            ])
        }

        // Create desired output format: 16 kHz, mono, 16-bit signed integer PCM
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioCapture", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create target recording format"
            ])
        }

        // Create a converter: hardware format → 16 kHz Int16 mono
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw NSError(domain: "AudioCapture", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create audio converter from \(hardwareFormat) to \(targetFormat)"
            ])
        }
        audioConverter = converter
        logger.info("Audio converter created: \(hardwareFormat.sampleRate) Hz → \(self.targetSampleRate) Hz")

        // Install tap using the HARDWARE format (required by AVAudioEngine).
        // We convert each buffer to the target format in the callback.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        logger.info("Audio engine started — recording")
    }

    /// Stop capturing audio and return the recorded data as a WAV file.
    /// - Returns: WAV-formatted audio data ready for the Gemini API
    func stopRecording() -> Data {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioConverter = nil

        let capturedPCM = pcmBuffer
        pcmBuffer = Data()

        logger.info("Recording stopped — captured \(capturedPCM.count) bytes of PCM data")

        // Convert raw PCM to WAV format
        return AudioProcessor.pcmToWAV(
            pcmData: capturedPCM,
            sampleRate: Int(targetSampleRate),
            channels: Int(targetChannelCount),
            bitsPerSample: 16
        )
    }

    // MARK: - Buffer Processing

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else { return }

        // Calculate how many output frames we need based on the sample rate ratio
        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return
        }

        // Convert from hardware format to target format
        var error: NSError?
        var allConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil else {
            logger.error("Audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return
        }

        // Extract Int16 samples from converted buffer
        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        let channelData = int16Data[0]

        // Calculate RMS audio level for UI visualization
        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = Float(channelData[i]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = sqrt(sum / max(Float(frameCount), 1))
        let levelDb = 20 * log10(max(rms, 0.0001))
        // Normalize to 0–1 range (assuming -60 dB to 0 dB range)
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
