import AudioToolbox
import Foundation

enum AudioWriterError: Error, CustomStringConvertible {
    case fileCreationFailed(OSStatus)
    case writeFailed(OSStatus)

    var description: String {
        switch self {
        case .fileCreationFailed(let status):
            return "Failed to create audio file (OSStatus: \(status))"
        case .writeFailed(let status):
            return "Failed to write audio data (OSStatus: \(status))"
        }
    }
}

/// Writes audio from the ring buffer to an M4A file (AAC 128kbps).
/// Runs on a background dispatch queue, draining the ring buffer every 10ms.
/// Handles Float32 → AAC conversion via ExtAudioFile.
class AudioWriter {
    private let ringBuffer: RingBuffer
    private let writerQueue = DispatchQueue(label: "com.meeting-recorder.writer")
    private var writerTimer: DispatchSourceTimer?
    private var extAudioFile: ExtAudioFileRef?
    private let inputFormat: AudioStreamBasicDescription
    private let outputPath: String

    // Conversion buffer: 200ms at 48kHz stereo Float32 = 76800 bytes
    private let conversionBufferSize: Int
    private let conversionBuffer: UnsafeMutableRawPointer

    init(ringBuffer: RingBuffer, inputFormat: AudioStreamBasicDescription, outputPath: String) {
        self.ringBuffer = ringBuffer
        self.inputFormat = inputFormat
        self.outputPath = outputPath

        // Buffer for 200ms of audio at the input format's rate
        let bytesPerFrame = Int(inputFormat.mBytesPerFrame)
        let framesPerChunk = Int(inputFormat.mSampleRate * 0.2)
        self.conversionBufferSize = framesPerChunk * bytesPerFrame
        self.conversionBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: conversionBufferSize, alignment: 16
        )
    }

    deinit {
        conversionBuffer.deallocate()
    }

    func start() throws {
        // Output format: AAC 128kbps (M4A container)
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputFormat.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let url = URL(fileURLWithPath: outputPath) as CFURL
        var fileRef: ExtAudioFileRef?

        let status = ExtAudioFileCreateWithURL(
            url,
            kAudioFileM4AType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard status == noErr, let file = fileRef else {
            throw AudioWriterError.fileCreationFailed(status)
        }
        extAudioFile = file

        // Set the client (input) format so ExtAudioFile handles Float32 → AAC conversion
        var clientFormat = inputFormat
        let clientStatus = ExtAudioFileSetProperty(
            file,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.stride),
            &clientFormat
        )
        guard clientStatus == noErr else {
            throw AudioWriterError.fileCreationFailed(clientStatus)
        }

        // Set AAC encoder bitrate to 128kbps
        var bitrate: UInt32 = 128000
        if let converter = getConverter(from: file) {
            AudioConverterSetProperty(
                converter,
                kAudioConverterEncodeBitRate,
                UInt32(MemoryLayout<UInt32>.size),
                &bitrate
            )
        }

        startWriterTimer()
        log("Writer started: \(outputPath)")
    }

    func stop() {
        writerTimer?.cancel()
        writerTimer = nil

        // Drain remaining data
        writerQueue.sync {
            self.drainRingBuffer()
        }

        if let file = extAudioFile {
            ExtAudioFileDispose(file)
            extAudioFile = nil
        }
        log("Writer stopped")
    }

    // MARK: - Private

    private func startWriterTimer() {
        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.drainRingBuffer()
        }
        timer.resume()
        writerTimer = timer
    }

    private func drainRingBuffer() {
        guard let file = extAudioFile else { return }

        let bytesPerFrame = Int(inputFormat.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }

        while ringBuffer.availableBytes >= bytesPerFrame {
            let maxBytes = min(ringBuffer.availableBytes, conversionBufferSize)
            // Align to frame boundary
            let framesToRead = maxBytes / bytesPerFrame
            let bytesToRead = framesToRead * bytesPerFrame
            guard bytesToRead > 0 else { break }

            let bytesRead = ringBuffer.read(conversionBuffer, count: bytesToRead)
            let framesRead = bytesRead / bytesPerFrame
            guard framesRead > 0 else { break }

            // Write to ExtAudioFile (handles Float32 → AAC conversion)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: inputFormat.mChannelsPerFrame,
                    mDataByteSize: UInt32(bytesRead),
                    mData: conversionBuffer
                )
            )

            let writeStatus = ExtAudioFileWrite(file, UInt32(framesRead), &bufferList)
            if writeStatus != noErr {
                log("Write error: \(writeStatus)")
                break
            }
        }
    }

    private func getConverter(from file: ExtAudioFileRef) -> AudioConverterRef? {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef>.stride)
        let status = ExtAudioFileGetProperty(
            file,
            kExtAudioFileProperty_AudioConverter,
            &size,
            &converter
        )
        return status == noErr ? converter : nil
    }
}
