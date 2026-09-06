//! Merge only compatible motion. Callers must exclude button transitions.
pub fn merge(previous: anytype, next: @TypeOf(previous.*)) bool {
    if (previous.kind != 2 or next.kind != 2 or previous.code != next.code) return false;
    // A reversal must remain distinct: clamping at a screen edge is ordered.
    if (!sameDirection(previous.dx, next.dx) or !sameDirection(previous.dy, next.dy)) return false;
    const dx = @addWithOverflow(previous.dx, next.dx);
    const dy = @addWithOverflow(previous.dy, next.dy);
    if (dx[1] != 0 or dy[1] != 0) return false;
    previous.dx = dx[0];
    previous.dy = dy[0];
    return true;
}

fn sameDirection(a: i32, b: i32) bool {
    return a == 0 or b == 0 or (a < 0) == (b < 0);
}

test "motion preserves totals, direction reversals, keys and buttons" {
    const std = @import("std");
    const E = struct { kind: u8 = 2, code: u8 = 0, dx: i32 = 0, dy: i32 = 0 };
    var e = E{ .dx = 10, .dy = -2 };
    try std.testing.expect(merge(&e, .{ .dx = 8, .dy = -3 }));
    try std.testing.expectEqual(@as(i32, 18), e.dx);
    try std.testing.expectEqual(@as(i32, -5), e.dy);
    try std.testing.expect(!merge(&e, .{ .dx = -1 }));
    try std.testing.expect(!merge(&e, .{ .code = 1, .dx = 1 }));
    try std.testing.expect(!merge(&e, .{ .kind = 1 }));
    try std.testing.expect(!merge(&e, .{ .dx = std.math.maxInt(i32) }));
    try std.testing.expectEqual(@as(i32, 18), e.dx);
}
