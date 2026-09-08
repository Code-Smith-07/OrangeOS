//! A bounded, pointer-free display model. Host timestamps are deliberately not
//! part of equality: unchanged hardware must not repaint every polling cycle.
const std = @import("std");
pub const Connection = enum { disconnected, invalid, unavailable, stale, fresh };
pub const Status = enum { available, unknown, unavailable, unsupported, ambiguous, permission_required, denied, restricted, stale };
pub const Reading = union(enum) { status: Status, on, off, percent: u8 };
pub const Source = struct {
    bytes: [46]u8 = @splat(0),
    len: u8 = 0,
    pub fn text(self: *const Source) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Row = struct { reading: Reading = .{ .status = .unavailable }, source: Source = .{} };
pub const Model = struct {
    connection: Connection = .disconnected,
    rows: [3]Row = @splat(.{}),
    pub fn eql(self: Model, other: Model) bool {
        return std.meta.eql(self, other);
    }
};
fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    const v = field(value, key) orelse return null;
    if (v != .string or v.string.len == 0 or v.string.len > 128) return null;
    // All v1 capability names are ASCII. Refuse control characters and reject
    // non-ASCII text instead of slicing an arbitrary UTF-8 sequence mid-glyph.
    for (v.string) |c| if (c < 32 or c > 126) return null;
    return v.string;
}
fn status(name: []const u8, permission: []const u8) Status {
    if (std.mem.eql(u8, name, "permission_required")) {
        if (std.mem.eql(u8, permission, "denied")) return .denied;
        if (std.mem.eql(u8, permission, "restricted")) return .restricted;
        return .permission_required;
    }
    inline for (.{ Status.available, Status.unknown, Status.unavailable, Status.unsupported, Status.ambiguous }) |s| {
        if (std.mem.eql(u8, name, @tagName(s))) return s;
    }
    return .unknown;
}
fn percentage(value: std.json.Value) ?u8 {
    // JSONEncoder may serialize Double(0) and Double(1) without a decimal.
    const number: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return null,
    };
    if (!std.math.isFinite(number) or number < 0 or number > 1) return null;
    return @intFromFloat(@round(number * 100));
}
pub fn parse(bytes: []const u8, scratch: []u8) Model {
    if (bytes.len == 0) return .{};
    const invalid: Model = .{ .connection = .invalid };
    if (bytes.len > 4096) return invalid;
    var allocator = std.heap.FixedBufferAllocator.init(scratch);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator.allocator(), bytes, .{}) catch return invalid;
    defer parsed.deinit();
    const root = parsed.value;
    const schema = field(root, "schema") orelse return invalid;
    if (schema != .integer or schema.integer != 1) return invalid;
    if (!std.mem.eql(u8, string(root, "provider") orelse return invalid, "macos")) return invalid;
    const observed = field(root, "observed_unix_seconds") orelse return invalid;
    if (observed != .integer or observed.integer < 0) return invalid;
    const freshness = string(root, "freshness") orelse return invalid;
    var result: Model = .{ .connection = if (std.mem.eql(u8, freshness, "fresh")) .fresh else if (std.mem.eql(u8, freshness, "stale")) .stale else if (std.mem.eql(u8, freshness, "unavailable")) .unavailable else return invalid };
    for ([_][]const u8{ "wifi", "bluetooth", "brightness" }, 0..) |key, i| {
        const item = field(root, key) orelse return invalid;
        const source = string(item, "source") orelse return invalid;
        const permission = string(item, "permission") orelse return invalid;
        const state = status(string(item, "status") orelse return invalid, permission);
        var row: Row = .{};
        row.source.len = @intCast(@min(source.len, row.source.bytes.len));
        @memcpy(row.source.bytes[0..row.source.len], source[0..row.source.len]);
        row.reading = .{ .status = if (result.connection == .fresh) state else if (result.connection == .stale) .stale else .unavailable };
        // Never allow an old/non-available payload's optional value to override
        // its authoritative status (e.g. denied plus a remembered power=true).
        if (result.connection == .fresh and state == .available) {
            if (i == 2) {
                if (field(item, "level")) |value| {
                    row.reading = if (percentage(value)) |p| .{ .percent = p } else .{ .status = .unknown };
                }
            } else if (field(item, "power")) |value| {
                row.reading = if (value == .bool) (if (value.bool) .on else .off) else .{ .status = .unknown };
            }
        }
        result.rows[i] = row;
    }
    return result;
}

const wifi = ",\"wifi\":{\"source\":\"CoreWLAN\",\"status\":\"available\",\"permission\":\"allowed\",\"power\":true}";
const bluetooth = ",\"bluetooth\":{\"source\":\"IOBluetooth\",\"status\":\"available\",\"permission\":\"allowed\",\"power\":false}";
const prefix = "{\"schema\":1,\"provider\":\"macos\",\"observed_unix_seconds\":100,\"freshness\":\"fresh\"";
const brightness = ",\"brightness\":{\"source\":\"IOKit\",\"status\":\"available\",\"permission\":\"allowed\",\"level\":";
fn decode(bytes: []const u8) Model {
    var scratch: [32768]u8 = undefined;
    return parse(bytes, &scratch);
}
test "available booleans and integer/float brightness endpoints" {
    const m = decode(prefix ++ wifi ++ bluetooth ++ brightness ++ "0}}");
    try std.testing.expect(m.connection == .fresh and m.rows[0].reading == .on and m.rows[1].reading == .off);
    try std.testing.expectEqual(@as(u8, 0), m.rows[2].reading.percent);
    try std.testing.expectEqual(@as(u8, 100), decode(prefix ++ wifi ++ bluetooth ++ brightness ++ "1}}").rows[2].reading.percent);
    try std.testing.expectEqual(@as(u8, 56), decode(prefix ++ wifi ++ bluetooth ++ brightness ++ "0.556}}").rows[2].reading.percent);
}
test "invalid or out-of-range values cannot masquerade as working controls" {
    inline for (.{ "-1", "1.01", "2", "\"0.5\"", "null", "true" }) |level| {
        try std.testing.expectEqual(Status.unknown, decode(prefix ++ wifi ++ bluetooth ++ brightness ++ level ++ "}}").rows[2].reading.status);
    }
    const denied = ",\"wifi\":{\"source\":\"CoreWLAN\",\"status\":\"permission_required\",\"permission\":\"denied\",\"power\":true}";
    try std.testing.expectEqual(Status.denied, decode(prefix ++ denied ++ bluetooth ++ brightness ++ "1}}").rows[0].reading.status);
    const unsupported = ",\"brightness\":{\"source\":\"IOKit\",\"status\":\"unsupported\",\"permission\":\"not_requested\",\"level\":1}}";
    try std.testing.expectEqual(Status.unsupported, decode(prefix ++ wifi ++ bluetooth ++ unsupported).rows[2].reading.status);
}
test "timestamps do not invalidate visible state but readings and expiry do" {
    const original = decode(prefix ++ wifi ++ bluetooth ++ brightness ++ "0.5}}");
    const next = "{\"schema\":1,\"provider\":\"macos\",\"observed_unix_seconds\":102,\"freshness\":\"fresh\"";
    try std.testing.expect(original.eql(decode(next ++ wifi ++ bluetooth ++ brightness ++ "0.5}}")));
    try std.testing.expect(!original.eql(decode(next ++ wifi ++ bluetooth ++ brightness ++ "0.6}}")));
    const stale = "{\"schema\":1,\"provider\":\"macos\",\"observed_unix_seconds\":100,\"freshness\":\"stale\"";
    const expired = decode(stale ++ wifi ++ bluetooth ++ brightness ++ "0.5}}");
    try std.testing.expect(!original.eql(expired));
    for (expired.rows) |row| try std.testing.expectEqual(Status.stale, row.reading.status);
    try std.testing.expect(!expired.eql(decode("")));
}
test "bounded parsing rejects malformed and incompatible snapshots" {
    inline for (.{ "[]", "{}", "{", "null", "{\"schema\":2}", "{\"schema\":1,\"provider\":\"other\"}", "{\"schema\":1,\"provider\":\"macos\",\"observed_unix_seconds\":0,\"freshness\":\"pretend\"}" }) |bytes| {
        try std.testing.expectEqual(Connection.invalid, decode(bytes).connection);
    }
    var oversized: [4097]u8 = @splat(' ');
    try std.testing.expectEqual(Connection.invalid, decode(&oversized).connection);
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqual(Connection.invalid, parse(prefix ++ wifi ++ bluetooth ++ brightness ++ "0.5}}", &tiny).connection);
    try std.testing.expectEqual(Connection.disconnected, decode("").connection);
}
