import Foundation
import CoreWLAN
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.graphics
import HostProtocol

/// Serial worker owns all OS queries. A stalled framework call cannot block
/// the RPC thread: its last snapshot expires instead. No scanning or writes.
public final class HardwareMonitor {
    private let queue = DispatchQueue(label: "org.orange.hardware.readback")
    private let lock = NSLock()
    private var snapshot = HardwareSnapshot()
    private var observedUptime: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private let audioConsent: AudioConsent
    public init(audioConsent: AudioConsent = AudioConsent()) {
        self.audioConsent = audioConsent
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }
    deinit { timer?.cancel() }
    public func current() -> HardwareSnapshot {
        lock.lock(); defer { lock.unlock() }
        var result = snapshot.aged(now: Date())
        if !audioConsent.allowed { result.audio.control = false; result.audio.permission = "not_granted" }
        if result.freshness == "fresh" && ProcessInfo.processInfo.systemUptime - observedUptime > 6 { result.freshness = "stale" }
        return result
    }
    private func refresh() {
        let started = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        // No SSID, BSSID, MAC address, paired-device names or credentials.
        let wifi: HardwareState
        if let iface = CWWiFiClient.shared().interface() {
            let on = iface.powerOn()
            wifi = .init(source: "CoreWLAN.powerOn", status: on ? "available" : "unknown", permission: "not_required_for_probe",
                         power: on ? true : nil, note: on ? "Host radio on; guest NAT health is separate" : "API false may mean off or query failure; not asserted as off")
        } else { wifi = .init(source: "CoreWLAN", status: "unavailable", note: "No interface returned") }
        let bluetooth: HardwareState
        // Authorization can be checked without creating a manager or prompting.
        switch CBManager.authorization {
        case .allowedAlways:
            if let controller = IOBluetoothHostController.default() {
                let state = controller.powerState.rawValue
                bluetooth = .init(source: "IOBluetooth.powerState", status: state <= 1 ? "available" : "unknown", permission: "allowed",
                                  power: state <= 1 ? state == 1 : nil, note: "Read-only radio state; discovery and pairing are separate grants")
            } else { bluetooth = .init(source: "IOBluetooth", status: "unavailable", permission: "allowed", note: "No host controller returned") }
        case .denied: bluetooth = .init(source: "CoreBluetooth.authorization", status: "permission_required", permission: "denied", note: "Host permission denied; no controller query")
        case .restricted: bluetooth = .init(source: "CoreBluetooth.authorization", status: "permission_required", permission: "restricted", note: "Restricted by host policy")
        default: bluetooth = .init(source: "CoreBluetooth.authorization", status: "permission_required", permission: "not_determined", note: "Companion onboarding required; no automatic permission prompt")
        }
        let brightness = Self.brightness()
        let value = HardwareSnapshot(observed: Int64(started.timeIntervalSince1970), freshness: "fresh", wifi: wifi, bluetooth: bluetooth, brightness: brightness,
                                     audio: AudioPower.audio(allowControl: audioConsent.allowed), battery: AudioPower.battery())
        lock.lock(); snapshot = value; observedUptime = startedUptime; lock.unlock()
    }
    private static func brightness() -> HardwareState {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            return .init(source: "IOKit.IODisplayGetFloatParameter", status: "unavailable", note: "Display service query failed")
        }
        defer { IOObjectRelease(iterator) }
        var levels: [Double] = []
        var truncated = false
        for i in 0...16 {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if i == 16 { truncated = true; break }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == KERN_SUCCESS,
               value.isFinite, value >= 0, value <= 1 { levels.append(Double(value)) }
        }
        if levels.count == 1 && !truncated {
            return .init(source: "IOKit.IODisplayGetFloatParameter", status: "available", permission: "not_required_for_probe", level: levels[0], note: "One readable display; write support not qualified")
        }
        return .init(source: "IOKit.IODisplayGetFloatParameter", status: levels.isEmpty ? "unsupported" : "ambiguous",
                     note: levels.isEmpty ? "No public IODisplay brightness endpoint; no private API fallback" : "Explicit display selection required")
    }
}
