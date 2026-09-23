import Foundation
import CoreGraphics
import Darwin
import HostProtocol

/// Compatibility adapter for the MacBook's built-in panel. Private API,
/// dynamically resolved and capability-probed; absent/changed APIs fail closed.
/// ABI reference: https://github.com/nriley/brightness/pull/36 (merged).
public enum BuiltinDisplay {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private static let get: Get? = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let set: Set? = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
    private static func display() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success, count < 16 else { return nil }
        let builtins = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
        return builtins.count == 1 ? builtins[0] : nil
    }
    private static func level(_ display: UInt32) -> Float? {
        guard let get else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    public static func read(allowControl: Bool) -> HardwareState {
        guard let display = display(), let level = level(display) else {
            return .init(source: "DisplayServices (compatibility)", status: "unsupported", note: "No readable built-in display; compatibility API may be unavailable")
        }
        var value = HardwareState(source: "DisplayServices (compatibility)", status: "available", permission: allowControl ? "allowed" : "not_granted",
                                  level: Double(level), note: "Mac built-in panel; private compatibility API")
        value.device = display; value.control = allowControl && set != nil
        return value
    }
    private static func write(display expected: UInt32, value: Float) -> String {
        guard display() == expected else { return "route_changed" }
        guard let set, level(expected) != nil else { return "unsupported" }
        guard set(expected, value) == 0 else { return "failed" }
        guard display() == expected, let actual = level(expected), abs(actual - value) <= 0.02 else { return "readback_failed" }
        return "applied"
    }
    public static func setPercent(display: UInt32, percent: UInt32) -> String {
        guard (5...100).contains(percent) else { return "invalid_argument" }
        return write(display: display, value: Float(percent) / 100)
    }
    public static func verifyUnchangedWrite() -> String {
        guard let display = display(), let value = level(display) else { return "unsupported" }
        return write(display: display, value: value)
    }
}

public final class BrightnessConsent {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public var allowed: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func setAllowed(_ allowed: Bool) { lock.lock(); value = allowed; lock.unlock() }
    public func apply(display: UInt32, percent: UInt32) -> String {
        lock.lock(); defer { lock.unlock() }
        guard value else { return "permission_denied" }
        return BuiltinDisplay.setPercent(display: display, percent: percent)
    }
}
