//! Notifications (docs/design/014, M6): a small store Peel owns. An app (or
//! Peel itself) posts a title and a body; the newest is shown as a banner
//! for a few seconds, and the last sixteen stay in the notification list
//! until cleared. Text is copied and cleaned here, so a client's buffer is
//! never referenced later. Pure logic, unit tested.
const std = @import("std");

pub const MAX = 16;
pub const BANNER_MS: u64 = 5000;

pub const Note = struct {
    title_buf: [48]u8 = undefined,
    title_len: usize = 0,
    body_buf: [120]u8 = undefined,
    body_len: usize = 0,
    /// Wall-clock seconds when it arrived (0: clock unavailable).
    at: u64 = 0,
    /// The application it came from (proto.App.*), for its icon.
    app: u32 = 0,

    pub fn title(self: *const Note) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn body(self: *const Note) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

pub const Store = struct {
    /// Newest first.
    items: [MAX]Note = undefined,
    count: usize = 0,
    unread: usize = 0,
    /// Uptime (ms) until which the newest is shown as a banner.
    banner_until: u64 = 0,
    serial: u64 = 0,

    /// Copy printable text only; other bytes become spaces.
    fn clean(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        for (src[0..n], 0..) |c, i| dst[i] = if (c >= 32 and c <= 126) c else ' ';
        return std.mem.trimRight(u8, dst[0..n], " ").len;
    }

    /// Add a notification; false when it has no title (nothing to show).
    pub fn post(self: *Store, title: []const u8, body: []const u8, app: u32, wall: u64, uptime_ms: u64) bool {
        var note = Note{ .at = wall, .app = app };
        note.title_len = clean(&note.title_buf, title);
        note.body_len = clean(&note.body_buf, body);
        if (note.title_len == 0) return false;
        var i = @min(self.count, MAX - 1);
        while (i > 0) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[0] = note;
        self.count = @min(self.count + 1, MAX);
        self.unread = @min(self.unread + 1, MAX);
        self.banner_until = uptime_ms + BANNER_MS;
        self.serial += 1;
        return true;
    }

    /// The notification to show as a banner now, if any.
    pub fn banner(self: *const Store, uptime_ms: u64) ?*const Note {
        if (self.count == 0 or uptime_ms >= self.banner_until) return null;
        return &self.items[0];
    }

    pub fn dismissBanner(self: *Store) void {
        self.banner_until = 0;
    }
    pub fn markRead(self: *Store) void {
        self.unread = 0;
    }
    pub fn clear(self: *Store) void {
        self.count = 0;
        self.unread = 0;
        self.banner_until = 0;
        self.serial += 1;
    }
};

const testing = std.testing;

test "notifications are kept newest first, cleaned and bounded" {
    var s = Store{};
    try testing.expect(!s.post("", "no title", 0, 0, 0));
    try testing.expect(s.post("Saved\x07", "notes.txt\nwas saved", 8, 100, 1000));
    try testing.expectEqualStrings("Saved", s.items[0].title());
    try testing.expectEqualStrings("notes.txt was saved", s.items[0].body());
    try testing.expect(s.banner(1000) != null and s.banner(5999) != null);
    try testing.expect(s.banner(6000) == null);
    for (0..40) |i| {
        var buf: [16]u8 = undefined;
        _ = s.post(std.fmt.bufPrint(&buf, "Note {d}", .{i}) catch unreachable, "", 0, 0, 2000);
    }
    try testing.expectEqual(@as(usize, MAX), s.count);
    try testing.expectEqual(@as(usize, MAX), s.unread);
    try testing.expectEqualStrings("Note 39", s.items[0].title());
    try testing.expectEqualStrings("Note 24", s.items[MAX - 1].title());
    s.markRead();
    try testing.expectEqual(@as(usize, 0), s.unread);
    s.dismissBanner();
    try testing.expect(s.banner(2001) == null);
    s.clear();
    try testing.expectEqual(@as(usize, 0), s.count);
}
