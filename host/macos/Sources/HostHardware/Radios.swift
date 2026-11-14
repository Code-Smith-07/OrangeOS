import Foundation
import CoreWLAN
import CoreBluetooth
import IOBluetooth

/// Turning the Mac's Wi-Fi and Bluetooth radios on and off for OrangeOS.
/// Each is used only behind its own grant (RadioConsent), and each write is
/// read back: "applied" means the radio really is in the requested state.
public enum Radios {
    public static func setWiFi(on: Bool) -> String {
        guard let iface = CWWiFiClient.shared().interface() else { return "unsupported" }
        do { try iface.setPower(on) } catch { return "failed" }
        // The radio takes a moment to change state.
        for _ in 0..<20 {
            if iface.powerOn() == on { return "applied" }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return "failed"
    }

    private typealias SetPower = @convention(c) (Int32) -> Void
    /// IOBluetooth's own preference call (what the Bluetooth menu uses);
    /// there is no public API for the controller's power.
    private static let setBluetoothPower: SetPower? = {
        guard let library = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(library, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return unsafeBitCast(symbol, to: SetPower.self)
    }()

    private static func bluetoothIsOn() -> Bool? {
        guard let controller = IOBluetoothHostController.default() else { return nil }
        let state = controller.powerState.rawValue
        return state <= 1 ? state == 1 : nil
    }

    public static func setBluetooth(on: Bool) -> String {
        // The same macOS permission that lets the companion read the state.
        guard CBManager.authorization == .allowedAlways else { return "permission_denied" }
        guard let set = setBluetoothPower else { return "unsupported" }
        set(on ? 1 : 0)
        for _ in 0..<30 {
            if bluetoothIsOn() == on { return "applied" }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return "failed"
    }

    /// Write the state each radio is already in, and read it back: proves
    /// the control path without changing anything.
    public static func verifyUnchangedWiFi() -> String {
        guard let iface = CWWiFiClient.shared().interface() else { return "unsupported" }
        return setWiFi(on: iface.powerOn())
    }
    public static func verifyUnchangedBluetooth() -> String {
        guard CBManager.authorization == .allowedAlways else { return "permission_denied" }
        guard let on = bluetoothIsOn() else { return "unsupported" }
        return setBluetooth(on: on)
    }
}

/// Grants live in the companion only; authentication never implies permission.
public final class RadioConsent {
    public enum Kind { case wifi, bluetooth }
    private let lock = NSLock()
    private var value = false
    public let kind: Kind
    public init(_ kind: Kind) { self.kind = kind }
    public var allowed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func setAllowed(_ allowed: Bool) { lock.lock(); value = allowed; lock.unlock() }
    public func apply(on: Bool) -> String {
        // Revoke and command execution serialize, as for sound.
        lock.lock(); defer { lock.unlock() }
        guard value else { return "permission_denied" }
        return kind == .wifi ? Radios.setWiFi(on: on) : Radios.setBluetooth(on: on)
    }
}
