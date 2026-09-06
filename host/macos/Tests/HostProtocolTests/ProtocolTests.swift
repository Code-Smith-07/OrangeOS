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
}
