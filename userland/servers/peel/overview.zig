//! Bounded overview caches. Stable IDs, not compacted window indices, identify
//! thumbnail content; revision changes come from the client's commit protocol.
const gfx = @import("gfx");
const std = @import("std");

pub const Preview = struct {
    pixels: [144 * 74]u32 = undefined,
    key: ?Key = null,
    builds: usize = 0,
    const Key = struct { id: u32, revision: u64, width: i32, height: i32, scale: i32 };

    pub fn paint(self: *Preview, s: *const gfx.Surface, source: [*]const u32, id: u32, revision: u64, width: i32, height: i32, x: i32, y: i32) void {
        const r = gfx.Rect{ .x = x, .y = y, .w = 72, .h = 37 };
        const area = gfx.Rect.intersect(gfx.Rect.intersect(r, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
        if (area.isEmpty() or width <= 0 or height <= 0 or s.scale < 1 or s.scale > 2) return;
        const key = Key{ .id = id, .revision = revision, .width = width, .height = height, .scale = s.scale };
        const tw = 72 * s.scale;
        const th = 37 * s.scale;
        if (self.key == null or !std.meta.eql(self.key.?, key)) {
            var yy: i32 = 0;
            while (yy < th) : (yy += 1) {
                var xx: i32 = 0;
                while (xx < tw) : (xx += 1) {
                    const fy = @divTrunc(yy * height * 256, th);
                    const fx = @divTrunc(xx * width * 256, tw);
                    const sy = @min(height - 1, fy >> 8);
                    const sx = @min(width - 1, fx >> 8);
                    const sy1 = @min(height - 1, sy + 1);
                    const sx1 = @min(width - 1, sx + 1);
                    const top = gfx.lerp(source[@intCast(sy * width + sx)], source[@intCast(sy * width + sx1)], @intCast(fx & 255));
                    const bottom = gfx.lerp(source[@intCast(sy1 * width + sx)], source[@intCast(sy1 * width + sx1)], @intCast(fx & 255));
                    self.pixels[@intCast(yy * tw + xx)] = gfx.lerp(top, bottom, @intCast(fy & 255));
                }
            }
            self.key = key;
            self.builds += 1;
        }
        var yy = area.y * s.scale;
        while (yy < area.bottom() * s.scale) : (yy += 1) {
            const from: usize = @intCast((yy - y * s.scale) * tw + (area.x - x) * s.scale);
            const to: usize = @intCast(yy * s.stride + area.x * s.scale);
            const len: usize = @intCast(area.w * s.scale);
            @memcpy(s.pixels[to..][0..len], self.pixels[from..][0..len]);
        }
    }
};

/// Finished glass/header pixels before cards are painted. Hover/card damage
/// restores these directly; it must never sample already-painted cards.
pub const Base = struct {
    pixels: [650 * 428 * 4]u32 = undefined,
    rect: gfx.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    scale: i32 = 0,
    valid: bool = false,

    pub fn capture(self: *Base, s: *const gfx.Surface, r: gfx.Rect) void {
        const area = gfx.Rect.intersect(gfx.Rect.intersect(r, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
        if (!std.meta.eql(area, r) or s.scale < 1 or s.scale > 2 or @as(i64, r.w) * r.h * s.scale * s.scale > self.pixels.len) {
            self.valid = false;
            return;
        }
        self.rect = r;
        self.scale = s.scale;
        var row: i32 = 0;
        while (row < r.h * s.scale) : (row += 1) {
            const from: usize = @intCast((r.y * s.scale + row) * s.stride + r.x * s.scale);
            const to: usize = @intCast(row * r.w * s.scale);
            const len: usize = @intCast(r.w * s.scale);
            @memcpy(self.pixels[to..][0..len], s.pixels[from..][0..len]);
        }
        self.valid = true;
    }

    pub fn restore(self: *const Base, s: *const gfx.Surface) bool {
        if (!self.valid or self.scale != s.scale) return false;
        const area = gfx.Rect.intersect(gfx.Rect.intersect(self.rect, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
        if (area.isEmpty()) return true;
        var y = area.y * s.scale;
        while (y < area.bottom() * s.scale) : (y += 1) {
            const from: usize = @intCast((y - self.rect.y * s.scale) * self.rect.w * s.scale + (area.x - self.rect.x) * s.scale);
            const to: usize = @intCast(y * s.stride + area.x * s.scale);
            const len: usize = @intCast(area.w * s.scale);
            @memcpy(s.pixels[to..][0..len], self.pixels[from..][0..len]);
        }
        return true;
    }
};

test "previews reuse unchanged revisions, invalidate identity and obey clips" {
    var preview: Preview = .{};
    var source = [_]u32{0x123456} ** 64;
    var pixels = [_]u32{0} ** (160 * 90);
    var s = gfx.Surface{ .pixels = &pixels, .width = 80, .height = 45, .stride = 160, .scale = 2 };
    preview.paint(&s, &source, 1, 0, 8, 8, 2, 2);
    try std.testing.expectEqual(@as(usize, 1), preview.builds);
    preview.paint(&s, &source, 1, 0, 8, 8, 2, 2);
    try std.testing.expectEqual(@as(usize, 1), preview.builds);
    @memset(&source, 0xABCDEF);
    s.setClip(.{ .x = 4, .y = 4, .w = 2, .h = 2 });
    preview.paint(&s, &source, 1, 1, 8, 8, 2, 2);
    try std.testing.expectEqual(@as(u32, 0xABCDEF), s.getPhysical(8, 8));
    try std.testing.expectEqual(@as(u32, 0x123456), s.getPhysical(6, 6));
    preview.paint(&s, &source, 2, 1, 8, 8, 2, 2);
    try std.testing.expectEqual(@as(usize, 3), preview.builds);
    s.setClip(.{ .x = 78, .y = 42, .w = 2, .h = 2 });
    preview.paint(&s, &source, 2, 2, 8, 8, 2, 2);
    try std.testing.expectEqual(@as(usize, 3), preview.builds);
}

test "base restores only damaged pixels and rejects partial capture" {
    const cache = try std.testing.allocator.create(Base);
    defer std.testing.allocator.destroy(cache);
    cache.* = .{};
    var pixels = [_]u32{0x123456} ** 64;
    var s = gfx.Surface{ .pixels = &pixels, .width = 8, .height = 8, .stride = 8 };
    cache.capture(&s, .{ .x = 1, .y = 1, .w = 6, .h = 6 });
    @memset(&pixels, 0);
    s.setClip(.{ .x = 2, .y = 2, .w = 2, .h = 2 });
    try std.testing.expect(cache.restore(&s));
    try std.testing.expectEqual(@as(u32, 0x123456), pixels[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0), pixels[1 * 8 + 1]);
    cache.capture(&s, .{ .x = 1, .y = 1, .w = 6, .h = 6 });
    try std.testing.expect(!cache.valid);
}

test "cached previews retain the original bilinear sampling at both scales" {
    var source: [13 * 11]u32 = undefined;
    for (&source, 0..) |*p, i| p.* = @intCast((i * 71893) & 0xFFFFFF);
    var pixels = [_]u32{0} ** (144 * 74);
    for ([_]i32{ 1, 2 }) |scale| {
        var preview: Preview = .{};
        const s = gfx.Surface{ .pixels = &pixels, .width = 72, .height = 37, .stride = 72 * scale, .scale = scale };
        preview.paint(&s, &source, 1, 0, 13, 11, 0, 0);
        var y: i32 = 0;
        while (y < 37 * scale) : (y += 1) {
            var x: i32 = 0;
            while (x < 72 * scale) : (x += 1) {
                const fy = @divTrunc(y * 11 * 256, 37 * scale);
                const fx = @divTrunc(x * 13 * 256, 72 * scale);
                const y0: usize = @intCast(@min(10, fy >> 8));
                const x0: usize = @intCast(@min(12, fx >> 8));
                const y1: usize = @min(10, y0 + 1);
                const x1: usize = @min(12, x0 + 1);
                const top = gfx.lerp(source[y0 * 13 + x0], source[y0 * 13 + x1], @intCast(fx & 255));
                const bottom = gfx.lerp(source[y1 * 13 + x0], source[y1 * 13 + x1], @intCast(fx & 255));
                try std.testing.expectEqual(gfx.lerp(top, bottom, @intCast(fy & 255)), s.getPhysical(x, y));
            }
        }
    }
}
