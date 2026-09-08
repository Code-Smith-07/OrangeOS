import XCTest
@testable import HostProtocol
final class ProtocolTests: XCTestCase {
    let token = Data(String(repeating:"a",count:64).utf8)
    func testGoldenHeaderAndFragmentation() throws {
        let f = Frame(method:4,request:0x12345678)
        let data = try f.encoded()
        XCTAssertEqual(Array(data),[79,82,72,66,1,0,4,0,120,86,52,18,0,0,0,0])
        var decoder = Decoder(); var frames:[Frame] = []
        for byte in data { frames += try decoder.feed(Data([byte])) }
        XCTAssertEqual(frames,[f])
        XCTAssertEqual(try decoder.feed(data+data),[f,f])
    }
    func testRejectBadHeadersImmediately() throws {
        for offset in [0,4,5,13] {
            var data = try Frame(method:4,request:1).encoded()
            data[offset] = 255
            var decoder = Decoder()
            XCTAssertThrowsError(try decoder.feed(data))
        }
    }
    func testAuthenticationAndReplay() throws {
        var s = try Session(token:token)
        XCTAssertThrowsError(try s.respond(Frame(method:3,request:1)))
        s = try Session(token:token)
        XCTAssertThrowsError(try s.respond(Frame(method:1,request:1,payload:Data(repeating:98,count:64))))
        s = try Session(token:token)
        XCTAssertEqual(try s.respond(Frame(method:1,request:1,payload:token)).flags,1)
        XCTAssertThrowsError(try s.respond(Frame(method:3,request:1)))
    }
    func testReadOnlyAllowlistAndSnapshot() throws {
        var s = try Session(token:token)
        _ = try s.respond(Frame(method:1,request:1,payload:token))
        let caps = try s.respond(Frame(method:2,request:2))
        XCTAssertTrue(String(decoding:caps.payload,as:UTF8.self).contains("not_implemented"))
        let snapshot = try s.respond(Frame(method:3,request:3),now:Date(timeIntervalSince1970:1234))
        let object = try JSONSerialization.jsonObject(with:snapshot.payload) as! [String:Any]
        XCTAssertEqual(object["unix_seconds"] as? Int,1234)
        XCTAssertEqual(try s.respond(Frame(method:100,request:4)).flags,2)
        XCTAssertEqual(try s.respond(Frame(method:3,request:5,payload:Data([1]))).flags,2)
    }
    func testHardwareRequiresAuthAndEmptyRequest() throws {
        var calls = 0
        var session = try Session(token: token, hardware: { calls += 1; return HardwareSnapshot(observed: 100, freshness: "fresh") })
        XCTAssertThrowsError(try session.respond(Frame(method: 5, request: 1)))
        XCTAssertEqual(calls, 0)
        _ = try session.respond(Frame(method: 1, request: 2, payload: token))
        XCTAssertEqual(try session.respond(Frame(method: 5, request: 3, payload: Data([1]))).flags, 2)
        XCTAssertEqual(calls, 0)
        let reply = try session.respond(Frame(method: 5, request: 4), now: Date(timeIntervalSince1970: 110))
        let snapshot = try JSONDecoder().decode(HardwareSnapshot.self, from: reply.payload)
        XCTAssertEqual(snapshot.freshness, "stale")
        XCTAssertNil(snapshot.wifi.power)
        XCTAssertNil(snapshot.brightness.level)
        XCTAssertEqual(calls, 1)
        XCTAssertLessThan(reply.payload.count, 4096)
        XCTAssertThrowsError(try session.respond(Frame(method: 5, request: 4)))
        XCTAssertEqual(try session.respond(Frame(method: 6, request: 5)).flags, 2)
        XCTAssertEqual(calls, 1)
    }
    func testHardwareFreshnessAndUnavailableProvider() throws {
        let value = HardwareSnapshot(observed: 100, freshness: "fresh")
        XCTAssertEqual(value.aged(now: Date(timeIntervalSince1970: 105)).freshness, "fresh")
        XCTAssertEqual(value.aged(now: Date(timeIntervalSince1970: 107)).freshness, "stale")
        XCTAssertEqual(value.aged(now: Date(timeIntervalSince1970: 99)).freshness, "stale")
        var session = try Session(token: token)
        _ = try session.respond(Frame(method: 1, request: 1, payload: token))
        XCTAssertEqual(try session.respond(Frame(method: 5, request: 2)).flags, 2)
    }
}
