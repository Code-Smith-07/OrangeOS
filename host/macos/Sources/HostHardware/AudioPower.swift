import Foundation
import CoreAudio
import AudioToolbox
import IOKit.ps
import HostProtocol

public enum AudioPower {
    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func outputDevice() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              size == MemoryLayout<AudioDeviceID>.size, device != kAudioObjectUnknown else { return nil }
        return device
    }
    private static func volume(_ device: AudioDeviceID) -> (AudioObjectPropertyAddress, Float32, Bool)? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var property = address(selector)
            guard AudioObjectHasProperty(device, &property) else { continue }
            var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
                  size == MemoryLayout<Float32>.size, value.isFinite, value >= 0, value <= 1 else { continue }
            var settable = DarwinBoolean(false)
            let writable = AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue
            return (property, value, writable)
        }
        return nil
    }
    public static func audio(allowControl: Bool) -> HardwareState {
        guard let device = outputDevice() else {
            return .init(source: "CoreAudio", status: "unavailable", note: "No default output device")
        }
        guard let (_, level, settable) = volume(device) else {
            return .init(source: "CoreAudio", status: "unsupported", note: "Default route has no readable main volume")
        }
        var state = HardwareState(source: "CoreAudio", status: "available", permission: allowControl ? "allowed" : "not_granted",
                                  level: Double(level), note: "Mac default sound output")
        state.device = device; state.control = allowControl && settable
        var muteProperty = address(kAudioDevicePropertyMute)
        var muted: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &muteProperty, 0, nil, &size, &muted) == noErr, size == 4 { state.muted = muted != 0 }
        return state
    }
    public static func setVolume(device expected: UInt32, percent: UInt32) -> String {
        guard percent <= 100 else { return "invalid_argument" }
        guard let device = outputDevice(), device == expected else { return "route_changed" }
        guard let reading = volume(device), reading.2 else { return "unsupported" }
        return writeVolume(device: device, property: reading.0, level: Float32(percent) / 100)
    }
    private static func writeVolume(device: AudioDeviceID, property originalProperty: AudioObjectPropertyAddress, level: Float32) -> String {
        guard outputDevice() == device else { return "route_changed" }
        var property = originalProperty, value = level
        guard AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr else { return "failed" }
        guard outputDevice() == device else { return "route_changed" }
        guard let (_, readback, _) = volume(device), abs(readback - value) <= 0.02 else { return "readback_failed" }
        return "applied"
    }
    /// Explicit diagnostic: write the current exact scalar back unchanged.
    /// Exercises the production setter without rounding or changing loudness.
    public static func verifyUnchangedVolumeWrite() -> String {
        guard let device = outputDevice(), let reading = volume(device), reading.2 else { return "unsupported" }
        return writeVolume(device: device, property: reading.0, level: reading.1)
    }
    public static func battery() -> HardwareState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .init(source: "IOPowerSources", status: "unavailable", note: "Power source query failed")
        }
        var readings: [HardwareState] = []
        for source in sources {
            guard let details = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  details[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = details[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = details[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0, current.doubleValue >= 0, current.doubleValue <= maximum.doubleValue else { continue }
            let ac = (details[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = (details[kIOPSIsChargingKey] as? Bool) == true
            readings.append(.init(source: "IOPowerSources", status: "available", permission: "not_required_for_probe", power: ac,
                                  level: current.doubleValue / maximum.doubleValue,
                                  note: charging ? "Charging" : ac ? "Connected to power" : "On battery"))
        }
        guard readings.count == 1 else {
            return .init(source: "IOPowerSources", status: readings.isEmpty ? "unavailable" : "ambiguous", note: "One internal battery required")
        }
        return readings[0]
    }
}

/// Grants live in the companion only; authentication never implies permission.
public final class AudioConsent {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var allowed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func setAllowed(_ allowed: Bool) { lock.lock(); value = allowed; lock.unlock() }
    public func apply(device: UInt32, percent: UInt32) -> String {
        // Revoke and command execution serialize: after revoke returns, no new
        // write authorized by the old grant can start.
        lock.lock(); defer { lock.unlock() }
        guard value else { return "permission_denied" }
        return AudioPower.setVolume(device: device, percent: percent)
    }
}
