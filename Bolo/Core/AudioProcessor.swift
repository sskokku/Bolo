import Foundation

/// Platform-agnostic audio processing utilities.
/// Handles PCM to WAV conversion and audio validation.
/// Uses only Foundation — no platform-specific imports.
struct AudioProcessor {

    /// Convert raw PCM data to WAV format suitable for Gemini API.
    ///
    /// - Parameters:
    ///   - pcmData: Raw 16-bit PCM audio samples
    ///   - sampleRate: Audio sample rate (default: 16000 Hz, optimal for speech)
    ///   - channels: Number of audio channels (default: 1, mono)
    ///   - bitsPerSample: Bit depth per sample (default: 16)
    /// - Returns: Complete WAV file data with headers
    static func pcmToWAV(
        pcmData: Data,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {

        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcmData.count
        let fileSize = 36 + dataSize

        var wavData = Data()
        wavData.reserveCapacity(44 + dataSize)

        // RIFF header
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLittleEndianUInt32(&wavData, UInt32(fileSize))
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLittleEndianUInt32(&wavData, 16) // chunk size
        appendLittleEndianUInt16(&wavData, 1)  // PCM format
        appendLittleEndianUInt16(&wavData, UInt16(channels))
        appendLittleEndianUInt32(&wavData, UInt32(sampleRate))
        appendLittleEndianUInt32(&wavData, UInt32(byteRate))
        appendLittleEndianUInt16(&wavData, UInt16(blockAlign))
        appendLittleEndianUInt16(&wavData, UInt16(bitsPerSample))

        // data chunk
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLittleEndianUInt32(&wavData, UInt32(dataSize))
        wavData.append(pcmData)

        return wavData
    }

    /// Validate that audio duration is within acceptable bounds.
    ///
    /// - Parameters:
    ///   - duration: Recording duration in seconds
    ///   - maxDuration: Maximum allowed duration (default: 300 seconds / 5 minutes)
    /// - Returns: true if duration is valid
    static func validate(duration: TimeInterval, maxDuration: TimeInterval = 300) -> Bool {
        return duration <= maxDuration && duration > 0.1
    }

    /// Calculate the approximate duration of PCM audio data.
    ///
    /// - Parameters:
    ///   - dataSize: Size of PCM data in bytes
    ///   - sampleRate: Sample rate in Hz
    ///   - channels: Number of channels
    ///   - bitsPerSample: Bits per sample
    /// - Returns: Duration in seconds
    static func estimateDuration(
        dataSize: Int,
        sampleRate: Int = 16000,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> TimeInterval {
        let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
        guard bytesPerSecond > 0 else { return 0 }
        return TimeInterval(dataSize) / TimeInterval(bytesPerSecond)
    }

    // MARK: - Private Helpers

    private static func appendLittleEndianUInt32(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 4))
    }

    private static func appendLittleEndianUInt16(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        data.append(Data(bytes: &le, count: 2))
    }
}
