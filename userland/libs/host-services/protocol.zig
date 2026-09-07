//! ORHB v1, shared golden wire format with the Swift companion. No allocations.
const std = @import("std");
pub const max_payload = 4096;
pub const Header = struct { flags: u8, method: u16, request: u32, length: usize };
pub const Error = error{InvalidHeader};
pub fn header(out: *[16]u8, flags: u8, method: u16, request: u32, length: usize) Error!void {
    if (flags > 2 or length > max_payload) return error.InvalidHeader;
    @memcpy(out[0..4], "ORHB");
    out[4] = 1;
    out[5] = flags;
    std.mem.writeInt(u16, out[6..8], method, .little);
    std.mem.writeInt(u32, out[8..12], request, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(length), .little);
}
pub fn decode(bytes: *const [16]u8) Error!Header {
    if (!std.mem.eql(u8, bytes[0..4], "ORHB") or bytes[4] != 1 or bytes[5] > 2) return error.InvalidHeader;
    const length = std.mem.readInt(u32, bytes[12..16], .little);
    if (length > max_payload) return error.InvalidHeader;
    return .{ .flags = bytes[5], .method = std.mem.readInt(u16, bytes[6..8], .little), .request = std.mem.readInt(u32, bytes[8..12], .little), .length = length };
}
pub const Decoder = struct {
    buffer: [16 + max_payload]u8 = undefined,
    count: usize = 0,
    expected: usize = 16,
    /// Returns true for one complete frame. Caller consumes then resets.
    pub fn feed(self: *Decoder, byte: u8) Error!bool {
        if (self.count >= self.buffer.len) return error.InvalidHeader;
        self.buffer[self.count] = byte;
        self.count += 1;
        if (self.count == 16) self.expected = 16 + (try decode(self.buffer[0..16])).length;
        return self.count == self.expected;
    }
    pub fn reset(self: *Decoder) void {
        self.count = 0;
        self.expected = 16;
    }
};
test "Swift-compatible golden header and fragmented frame" {
    var h: [16]u8 = undefined;
    try header(&h, 0, 4, 0x12345678, 0);
    try std.testing.expectEqualSlices(u8, &.{ 79, 82, 72, 66, 1, 0, 4, 0, 120, 86, 52, 18, 0, 0, 0, 0 }, &h);
    var parser: Decoder = .{};
    for (h, 0..) |b, i| try std.testing.expectEqual(i == 15, try parser.feed(b));
    try std.testing.expectEqual(@as(u32, 0x12345678), (try decode(parser.buffer[0..16])).request);
}
test "invalid magic, version, flags and oversized payload fail at header" {
    for ([_]usize{ 0, 4, 5, 13 }) |offset| {
        var h: [16]u8 = undefined;
        try header(&h, 0, 4, 1, 0);
        h[offset] = 255;
        try std.testing.expectError(error.InvalidHeader, decode(&h));
    }
}
