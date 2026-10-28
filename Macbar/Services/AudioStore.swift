import AppKit
import CoreAudio
import AudioToolbox

struct AudioOutputState {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var name = "No output device"
    var volume: Double = 0
    var muted = false
    var canSetVolume = false
    var canSetMute = false
}

protocol AudioOutputControlling {
    func readOutput() throws -> AudioOutputState
    func setVolume(_ volume: Double, device: AudioDeviceID) throws
    func setMuted(_ muted: Bool, device: AudioDeviceID) throws
}

private struct AudioControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct SystemAudioOutput: AudioOutputControlling {
    func readOutput() throws -> AudioOutputState {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device))
        guard device != kAudioObjectUnknown else { return AudioOutputState() }

        var name: Unmanaged<CFString>?
        address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        let outputName = name?.takeRetainedValue() as String? ?? "Audio output"

        let controls = volumeControls(device: device)
        let volume = controls.compactMap { readFloat(device: device, address: $0) }.max() ?? 0
        let muteAddress = outputAddress(kAudioDevicePropertyMute)
        var muted: UInt32 = 0
        var mutableMuteAddress = muteAddress
        size = UInt32(MemoryLayout<UInt32>.size)
        let hasMute = AudioObjectGetPropertyData(device, &mutableMuteAddress, 0, nil, &size, &muted) == noErr
        return AudioOutputState(deviceID: device, name: outputName, volume: Double(volume),
                                muted: (hasMute && muted != 0) || (!controls.isEmpty && volume == 0),
                                canSetVolume: !controls.isEmpty && controls.allSatisfy { isSettable(device: device, address: $0) },
                                canSetMute: hasMute && isSettable(device: device, address: muteAddress))
    }

    func setVolume(_ volume: Double, device: AudioDeviceID) throws {
        let controls = volumeControls(device: device)
        guard !controls.isEmpty else { throw AudioControlError(message: "This output has no software volume control.") }
        let current = controls.map { readFloat(device: device, address: $0) ?? 0 }
        let maximum = current.max() ?? 0
        for (index, control) in controls.enumerated() {
            // Preserve channel balance when a device only exposes individual channel controls.
            var value = Float(volume) * (maximum > 0 ? current[index] / maximum : 1)
            var address = control
            try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value))
        }
    }

    func setMuted(_ muted: Bool, device: AudioDeviceID) throws {
        var address = outputAddress(kAudioDevicePropertyMute)
        var value: UInt32 = muted ? 1 : 0
        try check(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    private func volumeControls(device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        // The virtual main control also preserves balance on multichannel devices.
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            let address = outputAddress(selector)
            if readFloat(device: device, address: address) != nil { return [address] }
        }
        // Ask for the actual output channel count instead of assuming stereo.
        var streamAddress = outputAddress(kAudioDevicePropertyStreamConfiguration)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &streamAddress, 0, nil, &size, buffer) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        let count = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard count > 0 else { return [] }
        return (1...count).map { outputAddress(kAudioDevicePropertyVolumeScalar, element: UInt32($0)) }
            .filter { readFloat(device: device, address: $0) != nil }
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func readFloat(device: AudioDeviceID, address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func isSettable(device: AudioDeviceID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var value: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &value) == noErr && value.boolValue
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioControlError(message: "The audio output couldn’t be updated (\(status)).") }
    }
}

@MainActor
final class AudioStore: ObservableObject {
    @Published private(set) var output = AudioOutputState()
    @Published private(set) var error: String?
    private let backend: AudioOutputControlling
    private var timer: Timer?
    private var lastAudibleVolume: Double = 0.3

    var symbol: String {
        if !output.canSetVolume && !output.canSetMute { return "speaker.wave.2" }
        if output.muted || output.volume == 0 { return "speaker.slash" }
        return output.volume < 0.34 ? "speaker.wave.1" : output.volume < 0.67 ? "speaker.wave.2" : "speaker.wave.3"
    }

    init(backend: AudioOutputControlling = SystemAudioOutput(), observeChanges: Bool = true) {
        self.backend = backend
        refresh()
        if observeChanges {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        do {
            output = try backend.readOutput()
            if output.volume > 0 { lastAudibleVolume = output.volume }
        } catch { self.error = error.localizedDescription }
    }

    func setVolume(_ value: Double) {
        guard output.canSetVolume else { return }
        let volume = min(1, max(0, value))
        do {
            try backend.setVolume(volume, device: output.deviceID)
            if output.canSetMute && volume > 0 && output.muted { try backend.setMuted(false, device: output.deviceID) }
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }

    func toggleMute() {
        do {
            if output.canSetMute {
                try backend.setMuted(!output.muted, device: output.deviceID)
                if output.muted && output.volume == 0 && output.canSetVolume {
                    try backend.setVolume(lastAudibleVolume, device: output.deviceID)
                }
            } else if output.canSetVolume {
                try backend.setVolume(output.muted ? lastAudibleVolume : 0, device: output.deviceID)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }
}
