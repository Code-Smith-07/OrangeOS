//! Relative device motion is not framebuffer pixels. DPI affects drawing,
//! not the distance travelled by the pointer.
pub const Motion = struct {
    x: i32,
    y: i32,
    pub fn move(self: *Motion, dx: i32, dy: i32, width: i32, height: i32) void {
        self.x = @intCast(@max(0, @min(@as(i64, self.x) + dx, width - 1)));
        self.y = @intCast(@max(0, @min(@as(i64, self.y) + dy, height - 1)));
    }
};

test "relative movement is independent of backing scale and safely clamps" {
    const std = @import("std");
    var p = Motion{ .x = 640, .y = 400 };
    p.move(20, -10, 1280, 800);
    try std.testing.expectEqual(@as(i32, 660), p.x);
    try std.testing.expectEqual(@as(i32, 390), p.y);
    p.move(std.math.maxInt(i32), std.math.minInt(i32), 1280, 800);
    try std.testing.expectEqual(@as(i32, 1279), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}
