import AVFoundation
import Foundation

/// Captures audio from the default input device (microphone) via AVAudioEngine.
/// Writes captured audio into a ring buffer for mixing with system audio.
class MicrophoneCapture {
    private var audioEngine: AVAudioEngine?
    private let ringBuffer: RingBuffer
    private(set) var inputFormat: AVAudioFormat?

    init(ringBuffer: RingBuffer) {
        self.ringBuffer = ringBuffer
    }

    /// Start capturing from the default input device.
    /// Returns the capture format (sample rate, channels) for downstream use.
    func start() throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw MicCaptureError.noInputDevice
        }

        log("Mic format: \(format.sampleRate) Hz, \(format.channelCount) ch")
        inputFormat = format

        // Install tap — callback fires on AVAudioEngine's internal thread
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            guard let channelData = buffer.floatChannelData else { return }

            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)

            if channelCount == 1 {
                // Mono mic — write directly (Float32, 4 bytes per sample)
                self.ringBuffer.write(channelData[0], count: frameCount * MemoryLayout<Float>.stride)
            } else {
                // Stereo or multi-channel — downmix to mono
                // Allocate on stack via withUnsafeTemporaryAllocation
                let monoBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: frameCount)
                defer { monoBuffer.deallocate() }

                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += channelData[ch][i]
                    }
                    monoBuffer[i] = sum / Float(channelCount)
                }

                self.ringBuffer.write(monoBuffer.baseAddress!, count: frameCount * 4)
            }
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        log("Microphone capture started")
        return format
    }

    func stop() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            log("Microphone capture stopped")
        }
    }

    deinit { stop() }
}

enum MicCaptureError: Error, CustomStringConvertible {
    case noInputDevice

    var description: String {
        switch self {
        case .noInputDevice:
            return "No microphone input device available. Check System Settings > Privacy & Security > Microphone."
        }
    }
}
