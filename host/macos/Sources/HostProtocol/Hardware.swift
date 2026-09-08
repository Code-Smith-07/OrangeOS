import Foundation

public struct HardwareState: Codable, Equatable {
    public var source: String
    public var status: String
    public var permission: String
    public var power: Bool?
    public var level: Double?
    public var note: String
    public init(source: String, status: String, permission: String = "not_requested",
                power: Bool? = nil, level: Double? = nil, note: String) {
        self.source = source; self.status = status; self.permission = permission
        self.power = power; self.level = level; self.note = note
    }
}

public struct HardwareSnapshot: Codable, Equatable {
    public var schema = 1
    public var provider = "macos"
    public var observed_unix_seconds: Int64
    public var freshness: String
    public var wifi: HardwareState
    public var bluetooth: HardwareState
    public var brightness: HardwareState
    public init(observed: Int64 = 0, freshness: String = "unavailable",
                wifi: HardwareState? = nil, bluetooth: HardwareState? = nil, brightness: HardwareState? = nil) {
        observed_unix_seconds = observed; self.freshness = freshness
        self.wifi = wifi ?? .init(source: "CoreWLAN", status: "unavailable", note: "Awaiting host probe")
        self.bluetooth = bluetooth ?? .init(source: "CoreBluetooth/IOBluetooth", status: "unavailable", note: "Awaiting host probe")
        self.brightness = brightness ?? .init(source: "IOKit", status: "unavailable", note: "Awaiting host probe")
    }
    public func aged(now: Date) -> HardwareSnapshot {
        var result = self
        if freshness == "fresh" && (now.timeIntervalSince1970 < Double(observed_unix_seconds) || now.timeIntervalSince1970 - Double(observed_unix_seconds) > 6) {
            result.freshness = "stale"
        }
        return result
    }
}
