import AudioToolbox
import CoreAudio
import Foundation

enum AudioCaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case tapAssignmentFailed(OSStatus)
    case formatQueryFailed(OSStatus)
    case ioProcFailed(OSStatus)

    var description: String {
        switch self {
        case .permissionDenied:
            return "System audio recording permission denied. Grant access in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .tapCreationFailed(let status):
            return "Failed to create audio tap (OSStatus: \(status))"
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device (OSStatus: \(status))"
        case .tapAssignmentFailed(let status):
            return "Failed to assign tap to aggregate device (OSStatus: \(status))"
        case .formatQueryFailed(let status):
            return "Failed to query tap format (OSStatus: \(status))"
        case .ioProcFailed(let status):
            return "Failed to create/start IOProc (OSStatus: \(status))"
        }
    }
}

/// Manages Core Audio Tap for system audio capture (macOS 14.2+).
/// Creates a process tap on all system audio, wraps it in a private aggregate
/// device, and provides the device ID for IOProc registration.
class AudioTapManager {
    private var tapID: AudioObjectID?
    private(set) var aggregateDeviceID: AudioObjectID?
    private(set) var tapFormat: AudioStreamBasicDescription?

    func setup(mute: Bool = false) throws {
        let tap = try createTap(mute: mute)
        tapID = tap

        tapFormat = try queryTapFormat(tapID: tap)
        log("Tap format: \(tapFormat!.mSampleRate) Hz, \(tapFormat!.mChannelsPerFrame) ch, \(tapFormat!.mBitsPerChannel) bit")

        let tapUID = try getTapUID(tapID: tap)
        let device = try createAggregateDevice(tapUID: tapUID)
        aggregateDeviceID = device

        log("Audio tap ready (device ID: \(device))")
    }

    func teardown() {
        if let deviceID = aggregateDeviceID {
            AudioHardwareDestroyAggregateDevice(deviceID)
            aggregateDeviceID = nil
        }
        if let tapID = tapID {
            AudioHardwareDestroyProcessTap(tapID)
            self.tapID = nil
        }
    }

    deinit { teardown() }

    // MARK: - Private

    private func createTap(mute: Bool) throws -> AudioObjectID {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "meeting-recorder-tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.isMixdown = true
        description.muteBehavior = mute ? .mutedWhenTapped : .unmuted

        var tapObjectID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapObjectID)

        if status == kAudioHardwareBadObjectError || status == OSStatus(kAudioHardwareNotRunningError) {
            throw AudioCaptureError.permissionDenied
        }
        guard status == kAudioHardwareNoError else {
            throw AudioCaptureError.tapCreationFailed(status)
        }
        return tapObjectID
    }

    private func queryTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        var format = AudioStreamBasicDescription()

        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw AudioCaptureError.formatQueryFailed(status)
        }
        return format
    }

    private func getTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.stride)
        var tapUID: CFString = "" as CFString

        let status = withUnsafeMutablePointer(to: &tapUID) { ptr in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else {
            throw AudioCaptureError.tapAssignmentFailed(status)
        }
        return tapUID as String
    }

    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: false,
        ]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "meeting-recorder-device",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]

        var deviceID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == kAudioHardwareNoError else {
            throw AudioCaptureError.aggregateDeviceCreationFailed(status)
        }
        return deviceID
    }
}
