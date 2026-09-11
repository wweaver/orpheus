import Foundation
import CoreAudio
import AudioToolbox

/// Read and write the macOS default output device's volume.
///
/// pianobar's FIFO has no absolute-volume command (`(` and `)` are relative
/// steps only), so the in-app slider drives system output volume instead.
///
/// Uses CoreAudio rather than an AppleScript `set volume`: the app ships with
/// `ENABLE_HARDENED_RUNTIME`, and driving this through NSAppleScript would put
/// it at the mercy of Apple-events permissions and a TCC prompt. CoreAudio
/// needs no entitlement and is synchronous and cheap.
enum SystemVolume {

    /// Current output volume as 0...100, or nil if the device has no
    /// settable main volume (some aggregate and HDMI devices don't).
    static func read() -> Int? {
        guard let device = defaultOutputDevice() else { return nil }
        var address = volumeAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        guard status == noErr else { return nil }
        return Int((volume * 100).rounded())
    }

    /// Set output volume. `value` is clamped to 0...100.
    @discardableResult
    static func set(_ value: Int) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue
        else { return false }

        var volume = Float32(max(0, min(100, value))) / 100
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &volume) == noErr
    }

    /// True when the current output device exposes a settable main volume, so
    /// the UI can hide the slider rather than show a dead control.
    static func isAvailable() -> Bool { read() != nil }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
