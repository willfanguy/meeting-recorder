import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Argument parsing

struct Config {
    var outputPath = "/tmp/meeting-recording-temp.m4a"
    var pidFile: String? = nil
    var mute = false
    var includeMic = false
    var micGain: Float = 0.5
}

func parseArgs() -> Config {
    var config = Config()
    var args = CommandLine.arguments.dropFirst()

    while let arg = args.popFirst() {
        switch arg {
        case "--output", "-o":
            guard let value = args.popFirst() else {
                fputs("Error: --output requires a path\n", stderr)
                exit(1)
            }
            config.outputPath = value
        case "--pid-file":
            guard let value = args.popFirst() else {
                fputs("Error: --pid-file requires a path\n", stderr)
                exit(1)
            }
            config.pidFile = value
        case "--mute":
            config.mute = true
        case "--include-mic":
            config.includeMic = true
        case "--mic-gain":
            guard let value = args.popFirst(), let gain = Float(value) else {
                fputs("Error: --mic-gain requires a number (0.0-1.0)\n", stderr)
                exit(1)
            }
            config.micGain = min(max(gain, 0.0), 1.0)
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            // If it looks like a bare path (no flag), treat as output
            if !arg.hasPrefix("-") && config.outputPath == "/tmp/meeting-recording-temp.m4a" {
                config.outputPath = arg
            } else {
                fputs("Unknown option: \(arg)\n", stderr)
                printUsage()
                exit(1)
            }
        }
    }
    return config
}

func printUsage() {
    let usage = """
    Usage: MeetingRecorder [options]

    Records system audio via Core Audio Taps (macOS 14.2+).
    Send SIGINT (Ctrl+C) to stop recording and finalize the file.

    Options:
      --output, -o PATH   Output file path (default: /tmp/meeting-recording-temp.m4a)
      --pid-file PATH     Write PID to this file (for external stop scripts)
      --include-mic       Also capture microphone audio (mixed into output)
      --mic-gain FLOAT    Microphone gain when mixing (0.0-1.0, default: 0.5)
      --mute              Mute system audio while recording
      --help, -h          Show this help

    Examples:
      MeetingRecorder --output recording.m4a --pid-file /tmp/recorder.pid
      MeetingRecorder -o /tmp/meeting.m4a --include-mic

    """
    fputs(usage, stderr)
}

// MARK: - Signal handling

enum SignalHandler {
    private static var sources: [DispatchSourceSignal] = []

    static func install(handler: @escaping () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { handler() }
            source.resume()
            sources.append(source)
        }
    }
}

// MARK: - Main

let config = parseArgs()

// Write PID file for external stop scripts (same pattern as ffmpeg approach)
if let pidFile = config.pidFile {
    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
        toFile: pidFile, atomically: true, encoding: .utf8
    )
}

log("Starting system audio capture -> \(config.outputPath)")

// 1. Set up the audio tap (Core Audio Taps API)
let tapManager = AudioTapManager()
do {
    try tapManager.setup(mute: config.mute)
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}

guard let deviceID = tapManager.aggregateDeviceID,
      let tapFormat = tapManager.tapFormat else {
    fputs("Error: Audio tap setup incomplete\n", stderr)
    exit(1)
}

// 2. Set up ring buffers, optional mic capture, and file writer
let ringBuffer = RingBuffer()
var micRingBuffer: RingBuffer? = nil
var micCapture: MicrophoneCapture? = nil

if config.includeMic {
    let micRing = RingBuffer()
    micRingBuffer = micRing
    let mic = MicrophoneCapture(ringBuffer: micRing)
    do {
        let micFormat = try mic.start()
        log("Mic capture active: \(micFormat.sampleRate) Hz, \(micFormat.channelCount) ch, gain=\(config.micGain)")
        micCapture = mic
    } catch {
        fputs("Warning: Mic capture failed (\(error)), continuing with system audio only\n", stderr)
        log("Mic capture failed (non-fatal): \(error)")
    }
}

let writer = AudioWriter(
    ringBuffer: ringBuffer, inputFormat: tapFormat, outputPath: config.outputPath,
    micRingBuffer: micRingBuffer, micGain: config.micGain
)
do {
    try writer.start()
} catch {
    fputs("Error: \(error)\n", stderr)
    micCapture?.stop()
    tapManager.teardown()
    exit(1)
}

// 3. Register IOProc — the real-time audio callback
// Pass ring buffer as unretained client data (it outlives the IOProc)
let clientData = Unmanaged.passUnretained(ringBuffer).toOpaque()
var ioProcID: AudioDeviceIOProcID?

let ioProcStatus = AudioDeviceCreateIOProcID(
    deviceID,
    { (inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime, inClientData) -> OSStatus in
        guard let clientData = inClientData else { return noErr }
        let ringBuffer = Unmanaged<RingBuffer>.fromOpaque(clientData).takeUnretainedValue()
        let bufferList = inInputData.pointee
        let buf = bufferList.mBuffers
        guard let data = buf.mData, buf.mDataByteSize > 0 else { return noErr }
        ringBuffer.write(data, count: Int(buf.mDataByteSize))
        return noErr
    },
    clientData,
    &ioProcID
)

guard ioProcStatus == noErr, let procID = ioProcID else {
    fputs("Error: Failed to create IOProc (OSStatus: \(ioProcStatus))\n", stderr)
    writer.stop()
    tapManager.teardown()
    exit(1)
}

// 4. Start the audio device
let startStatus = AudioDeviceStart(deviceID, procID)
guard startStatus == noErr else {
    fputs("Error: Failed to start audio device (OSStatus: \(startStatus))\n", stderr)
    AudioDeviceDestroyIOProcID(deviceID, procID)
    writer.stop()
    tapManager.teardown()
    exit(1)
}

log("Recording... (send SIGINT to stop)")

// 5. Install signal handler for graceful shutdown
SignalHandler.install {
    log("Stopping recording...")

    AudioDeviceStop(deviceID, procID)
    AudioDeviceDestroyIOProcID(deviceID, procID)

    micCapture?.stop()
    writer.stop()
    tapManager.teardown()

    // Clean up PID file
    if let pidFile = config.pidFile {
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    // Check file size
    if let attrs = try? FileManager.default.attributesOfItem(atPath: config.outputPath),
       let size = attrs[.size] as? UInt64 {
        log("Recording saved: \(config.outputPath) (\(size) bytes)")
        if size < 10000 {
            fputs("WARNING: Recording file very small (\(size) bytes) — may have captured silence\n", stderr)
        }
    }

    exit(0)
}

// 6. Block forever — signal handler handles shutdown
dispatchMain()
