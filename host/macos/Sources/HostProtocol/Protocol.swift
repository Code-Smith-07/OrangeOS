import Foundation

// ORHB v1: magic[4], version:u8, flags:u8, method:u16, request:u32,
// payload length:u32. Integers little endian. 4 KiB payload cap for read-only v1.
public enum WireError: Error { case malformed, oversized, authentication, sequence }
public struct Frame: Equatable {
    public let flags: UInt8
    public let method: UInt16
    public let request: UInt32
    public let payload: Data
    public init(flags: UInt8 = 0, method: UInt16, request: UInt32, payload: Data = Data()) {
        self.flags = flags; self.method = method; self.request = request; self.payload = payload
    }
    public func encoded() throws -> Data {
        guard payload.count <= 4096 else { throw WireError.oversized }
        var bytes: [UInt8] = [79,82,72,66,1,flags]
        for i in 0..<2 { bytes.append(UInt8(truncatingIfNeeded: method >> (i*8))) }
        for v in [request, UInt32(payload.count)] {
            for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (i*8))) }
        }
        return Data(bytes) + payload
    }
}

public struct Decoder {
    private var bytes = [UInt8]()
    public init() {}
    // Feed byte-by-byte so concatenated valid frames never require an unbounded
    // accumulation. Oversized declared lengths are rejected at the header.
    public mutating func feed(_ data: Data) throws -> [Frame] {
        guard data.count <= 8192 else { throw WireError.oversized }
        var frames: [Frame] = []
        for byte in data {
            bytes.append(byte)
            if bytes.count < 16 { continue }
            guard Array(bytes[0..<4]) == [79,82,72,66], bytes[4] == 1,
                  bytes[5] <= 2 else { throw WireError.malformed }
            func u32(_ p: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[p+$1]) << ($1*8) }
            }
            let length = Int(u32(12))
            guard length <= 4096 else { throw WireError.oversized }
            if bytes.count == 16 + length {
                frames.append(Frame(flags: bytes[5], method: UInt16(bytes[6]) | UInt16(bytes[7]) << 8,
                                    request: u32(8), payload: Data(bytes.dropFirst(16))))
                bytes.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }
}

public struct Session {
    private let token: Data
    private var authenticated = false
    private var lastRequest: UInt32 = 0
    public init(token: Data) throws {
        guard token.count == 64, token.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WireError.authentication
        }
        self.token = token
    }
    public mutating func respond(_ frame: Frame, now: Date = Date()) throws -> Frame {
        guard frame.flags == 0, frame.request > lastRequest else { throw WireError.sequence }
        lastRequest = frame.request
        if !authenticated {
            guard frame.method == 1, frame.payload.count == token.count else { throw WireError.authentication }
            var difference: UInt8 = 0
            for (a,b) in zip(frame.payload, token) { difference |= a ^ b }
            guard difference == 0 else { throw WireError.authentication }
            authenticated = true
            return try reply(frame, ["status":"ready", "protocol":1, "mode":"read_only"])
        }
        guard frame.payload.isEmpty else { return try reply(frame, ["error":"invalid_argument"], error: true) }
        switch frame.method {
        case 2:
            return try reply(frame, ["provider":"macos", "mode":"read_only",
                "operations":["host.capabilities","host.snapshot","host.ping"],
                "wifi":"not_implemented", "bluetooth":"not_implemented", "brightness":"not_implemented",
                "capture":"disabled", "host_mutations":"denied"])
        case 3:
            return try reply(frame, ["provider":"macos", "unix_seconds":Int64(now.timeIntervalSince1970),
                "timezone":TimeZone.current.identifier,
                "utc_offset_seconds":TimeZone.current.secondsFromGMT(for: now),
                "os_version":ProcessInfo.processInfo.operatingSystemVersionString])
        case 4: return try reply(frame, ["status":"pong"])
        default: return try reply(frame, ["error":"method_denied"], error: true)
        }
    }
    private func reply(_ f: Frame, _ object: [String:Any], error: Bool = false) throws -> Frame {
        Frame(flags: error ? 2 : 1, method: f.method, request: f.request,
              payload: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
}
