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
pub const MAX_COLUMNS = 200;
pub fn lineAt(text: []const u8, start: usize) Line {
    return lineAtWidth(text, start, COLUMNS);
}
/// One visual line of at most `width` characters, starting at `start`.
pub fn lineAtWidth(text: []const u8, start: usize, width: usize) Line {
    var end = @min(start, text.len);
    var columns: usize = 0;
    while (end < text.len and text[end] != '\n') : (end += 1) {
        if (text[end] == '\r') continue;
        if (columns == width) break;
        columns += 1;
    }
    return .{ .start = @min(start, text.len), .end = end, .next = end + @intFromBool(end < text.len and text[end] == '\n') };
}
pub fn lineCount(text: []const u8) usize {
    return lineCountWidth(text, COLUMNS);
}
pub fn lineCountWidth(text: []const u8, width: usize) usize {
    var pos: usize = 0;
    var count: usize = 0;
    while (pos < text.len) {
        pos = lineAtWidth(text, pos, @max(1, width)).next;
        count += 1;
    }
    return count;
}

// ── Names (docs/design/014, M3) ───────────────────────────────────────────

pub const MAX_NAME = 60;

pub const NameProblem = enum { ok, empty, too_long, slash, dot, unprintable };

/// Whether `name` can be given to a new file or folder.
pub fn checkName(name: []const u8) NameProblem {
    if (name.len == 0 or std.mem.trim(u8, name, " ").len == 0) return .empty;
    if (name.len > MAX_NAME) return .too_long;
    // Names starting with a dot are hidden, and . and .. are not names.
    if (name[0] == '.') return .dot;
    for (name) |c| {
        if (c == '/') return .slash;
        if (c < 32 or c > 126) return .unprintable;
    }
    if (name[0] == ' ' or name[name.len - 1] == ' ') return .empty;
    return .ok;
}

pub fn problemText(p: NameProblem) []const u8 {
    return switch (p) {
        .ok => "",
        .empty => "Type a name (it cannot start or end with a space).",
        .too_long => "That name is too long (60 characters at most).",
        .slash => "A name cannot contain a slash.",
        .dot => "A name cannot start with a dot.",
        .unprintable => "Use letters, numbers and ordinary symbols.",
    };
}

/// `name` with a number before its extension: ("notes.txt", 2) gives
/// "notes 2.txt", ("Photos", 3) gives "Photos 3". For a name already taken.
pub fn numbered(name: []const u8, n: usize, out: []u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const stem = if (dot != null and dot.? > 0) name[0..dot.?] else name;
    const ext = name[stem.len..];
    return std.fmt.bufPrint(out, "{s} {d}{s}", .{ stem, n, ext }) catch null;
}

/// A size for people: "512 bytes", "3.4 KB", "12 MB".
pub fn sizeText(bytes: u64, out: []u8) []const u8 {
    if (bytes < 1000) return std.fmt.bufPrint(out, "{d} bytes", .{bytes}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB" };
    var value = bytes;
    var unit: usize = 0;
    while (value >= 1000 * 1000 and unit + 1 < units.len) : (unit += 1) value /= 1000;
    // One decimal below 10, none above.
    const whole = value / 1000;
    const tenth = (value % 1000) / 100;
    if (whole < 10 and tenth != 0) return std.fmt.bufPrint(out, "{d}.{d} {s}", .{ whole, tenth, units[unit] }) catch "";
    return std.fmt.bufPrint(out, "{d} {s}", .{ whole, units[unit] }) catch "";
}

// ── Where trashed items came from ─────────────────────────────────────────
// The Trash keeps one text file, a line per item: its name in the Trash, a
// tab, and the full path it was moved from. Put Back reads it.

/// The original path recorded for `name`, or null.
pub fn originOf(origins: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, origins, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        // The newest line wins if a name was reused.
        if (std.mem.eql(u8, line[0..tab], name) and line.len > tab + 1) found = line[tab + 1 ..];
    }
    return found;
}

/// `origins` without the lines for `name`, written to `out`.
pub fn withoutOrigin(origins: []const u8, name: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    var lines = std.mem.splitScalar(u8, origins, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], name)) continue;
        if (len + line.len + 1 > out.len) break;
        @memcpy(out[len..][0..line.len], line);
        out[len + line.len] = '\n';
        len += line.len + 1;
    }
    return out[0..len];
}

/// The folder a path is in ("/data/Documents/a.txt" gives "/data/Documents").
pub fn parentOf(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (cut == 0) "/" else path[0..cut];
}

test "names are checked before anything is created" {
    try std.testing.expectEqual(NameProblem.ok, checkName("Holiday plans.txt"));
    try std.testing.expectEqual(NameProblem.empty, checkName(""));
    try std.testing.expectEqual(NameProblem.empty, checkName("   "));
    try std.testing.expectEqual(NameProblem.empty, checkName("trailing "));
    try std.testing.expectEqual(NameProblem.slash, checkName("a/b"));
    try std.testing.expectEqual(NameProblem.dot, checkName(".."));
    try std.testing.expectEqual(NameProblem.dot, checkName(".hidden"));
    try std.testing.expectEqual(NameProblem.unprintable, checkName("tab\there"));
    try std.testing.expectEqual(NameProblem.too_long, checkName("x" ** 61));
    inline for (std.meta.tags(NameProblem)) |p| try std.testing.expect((p == .ok) == (problemText(p).len == 0));
}

test "a taken name gets a number before its extension" {
    var buf: [80]u8 = undefined;
    try std.testing.expectEqualStrings("notes 2.txt", numbered("notes.txt", 2, &buf).?);
    try std.testing.expectEqualStrings("Photos 3", numbered("Photos", 3, &buf).?);
    try std.testing.expectEqualStrings("archive.tar 2.gz", numbered("archive.tar.gz", 2, &buf).?);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(numbered("notes.txt", 2, &tiny) == null);
}

test "sizes read naturally" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("0 bytes", sizeText(0, &buf));
    try std.testing.expectEqualStrings("999 bytes", sizeText(999, &buf));
    try std.testing.expectEqualStrings("1 KB", sizeText(1000, &buf));
    try std.testing.expectEqualStrings("3.4 KB", sizeText(3450, &buf));
    try std.testing.expectEqualStrings("64 KB", sizeText(64_000, &buf));
    try std.testing.expectEqualStrings("1.5 MB", sizeText(1_500_000, &buf));
    try std.testing.expectEqualStrings("2 GB", sizeText(2_000_000_000, &buf));
}

test "the Trash remembers where each item came from" {
    const origins = "a.txt\t/data/Documents/a.txt\nPhotos\t/data/Documents/Trips/Photos\na.txt\t/data/Documents/Work/a.txt\nbroken line\n";
    try std.testing.expectEqualStrings("/data/Documents/Work/a.txt", originOf(origins, "a.txt").?);
    try std.testing.expectEqualStrings("/data/Documents/Trips/Photos", originOf(origins, "Photos").?);
    try std.testing.expect(originOf(origins, "missing") == null);
    try std.testing.expect(originOf(origins, "a") == null);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Photos\t/data/Documents/Trips/Photos\n", withoutOrigin(origins, "a.txt", &buf));
    try std.testing.expectEqualStrings("/data/Documents/Trips", parentOf("/data/Documents/Trips/Photos"));
    try std.testing.expectEqualStrings("/", parentOf("/etc"));
}

test "text wraps to any width without losing bytes" {
    const text = "abcdefghij\nxy";
    try std.testing.expectEqual(@as(usize, 2), lineCountWidth(text, 80));
    try std.testing.expectEqual(@as(usize, 4), lineCountWidth(text, 4));
    const first = lineAtWidth(text, 0, 4);
    try std.testing.expectEqualStrings("abcd", text[first.start..first.end]);
    try std.testing.expectEqual(lineCount(text), lineCountWidth(text, COLUMNS));
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
