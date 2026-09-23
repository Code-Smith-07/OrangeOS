//! Pure, bounded search and text wrapping shared by rendering and tests.
const std = @import("std");

pub fn matches(name: []const u8, query: []const u8) bool {
    if (query.len > name.len) return false;
    for (0..name.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(name[i..][0..query.len], query)) return true;
    }
    return false;
}

pub const Line = struct { start: usize, end: usize, next: usize };
pub const COLUMNS = 55; // 440 logical pixels in the 450-pixel preview area.
pub fn lineAt(text: []const u8, start: usize) Line {
    var end = @min(start, text.len);
    var columns: usize = 0;
    while (end < text.len and text[end] != '\n') : (end += 1) {
        if (text[end] == '\r') continue;
        if (columns == COLUMNS) break;
        columns += 1;
    }
    return .{ .start = @min(start, text.len), .end = end, .next = end + @intFromBool(end < text.len and text[end] == '\n') };
}
pub fn lineCount(text: []const u8) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < text.len) {
        pos = lineAt(text, pos).next;
        count += 1;
    }
    return count;
}

test "substring search is case insensitive and handles empty/boundary queries" {
    try std.testing.expect(matches("OFL-Inter.txt", "inter"));
    try std.testing.expect(matches("motd", "MOTD"));
    try std.testing.expect(matches("motd", ""));
    try std.testing.expect(!matches("motd", "motds"));
    try std.testing.expect(!matches("motd", "seed"));
}
test "wrapped preview lines neither lose nor duplicate bytes at boundaries" {
    const text = "a" ** COLUMNS ++ "\r\nlast\n";
    const first = lineAt(text, 0);
    try std.testing.expectEqual(@as(usize, COLUMNS + 1), first.end);
    try std.testing.expectEqual(@as(usize, COLUMNS + 2), first.next);
    try std.testing.expectEqualStrings("last", text[lineAt(text, first.next).start..lineAt(text, first.next).end]);
    try std.testing.expectEqual(@as(usize, 2), lineCount(text));
    try std.testing.expectEqual(@as(usize, 2), lineCount("b" ** (COLUMNS + 1)));
    try std.testing.expectEqual(@as(usize, 2), lineCount("\n\n"));
    try std.testing.expectEqual(@as(usize, 0), lineCount(""));
}
