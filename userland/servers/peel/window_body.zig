//! One rounded body silhouette, like overflow:hidden on a rounded container.
//! Edge pixels blend against the real backdrop, never a pale frame undercoat.
const gfx = @import("gfx");
const Rect = gfx.Rect;

/// Borderless panel over a compositor-frosted backdrop. Native-size client
/// pixels retain their antialiasing; the subtle material opacity is uniform.
pub fn paintPanel(s: *const gfx.Surface, frame: Rect, src: [*]const u32) void {
    const area = Rect.intersect(Rect.intersect(frame, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
    const sc = s.scale;
    const radius = @min(13, @divTrunc(@min(frame.w, frame.h), 2)) * sc;
    var y = area.y * sc;
    while (y < area.bottom() * sc) : (y += 1) {
        var x = area.x * sc;
        while (x < area.right() * sc) : (x += 1) {
            const mirrored_y = if (y < (frame.y + @divTrunc(frame.h, 2)) * sc) (frame.y + frame.bottom()) * sc - 1 - y else y;
            const coverage = bottomCoverage(frame, sc, radius, x, mirrored_y);
            const alpha: u8 = @intCast(@as(u32, coverage) * 238 / 255);
            if (alpha == 0) continue;
            const from: usize = @intCast((y - frame.y * sc) * frame.w * sc + x - frame.x * sc);
            const to: usize = @intCast(y * s.stride + x);
            s.pixels[to] = gfx.lerp(s.pixels[to], src[from], alpha);
        }
    }
}

test "panel has four symmetric transparent corners and respects damage" {
    const std = @import("std");
    const source = [_]u32{0x283044} ** (40 * 40 * 4);
    var pixels: [60 * 60 * 4]u32 = undefined;
    for ([_]i32{ 1, 2 }) |sc| {
        @memset(&pixels, 0xCC8855);
        var s = gfx.Surface{ .pixels = &pixels, .width = 60, .height = 60, .stride = 60 * sc, .scale = sc };
        const r = Rect{ .x = 10, .y = 10, .w = 40, .h = 40 };
        paintPanel(&s, r, &source);
        try std.testing.expectEqual(@as(u32, 0xCC8855), s.getPhysical(10 * sc, 10 * sc));
        try std.testing.expectEqual(gfx.lerp(0xCC8855, 0x283044, 238), s.getPhysical(30 * sc, 30 * sc));
        for (0..@intCast(60 * sc)) |y| for (0..@intCast(60 * sc)) |x| {
            try std.testing.expectEqual(s.getPhysical(@intCast(x), @intCast(y)), s.getPhysical(@intCast(60 * sc - 1 - @as(i32, @intCast(x))), @intCast(60 * sc - 1 - @as(i32, @intCast(y)))));
        };
        const full = pixels;
        @memset(&pixels, 0xCC8855);
        s.setClip(.{ .x = 13, .y = 14, .w = 12, .h = 17 });
        paintPanel(&s, r, &source);
        for (0..@intCast(60 * sc)) |y| for (0..@intCast(60 * sc)) |x| {
            const inside = x >= 13 * sc and x < 25 * sc and y >= 14 * sc and y < 31 * sc;
            const i = y * @as(usize, @intCast(60 * sc)) + x;
            try std.testing.expectEqual(if (inside) full[i] else @as(u32, 0xCC8855), pixels[i]);
        };
    }
}

pub fn paint(s: *const gfx.Surface, frame: Rect, content: Rect, src: [*]const u32, source_w: i32, source_h: i32) void {
    paintImpl(s, frame, content, src, source_w, source_h, true);
}

fn paintImpl(s: *const gfx.Surface, frame: Rect, content: Rect, src: [*]const u32, source_w: i32, source_h: i32, fast: bool) void {
    if (source_w <= 0 or source_h <= 0 or content.w <= 0 or content.h <= 0) return;
    const body = Rect{ .x = frame.x, .y = content.y, .w = frame.w, .h = frame.bottom() - content.y };
    const area = Rect.intersect(Rect.intersect(body, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
    if (area.isEmpty()) return;
    const sc = s.scale;
    const radius = @min(13, @divTrunc(@min(frame.w, frame.h), 2)) * sc;
    var y = area.y * sc;
    while (y < area.bottom() * sc) : (y += 1) {
        const sy = @max(0, @min(source_h * sc - 1, @divTrunc((y - content.y * sc) * source_h, content.h)));
        const bottom_corner = y >= frame.bottom() * sc - radius;
        const copy_left = @max(content.x * sc, if (bottom_corner) frame.x * sc + radius else content.x * sc);
        const copy_right = @min(content.right() * sc, if (bottom_corner) frame.right() * sc - radius else content.right() * sc);
        // Preserve the bulk-copy interior. Only edges and corner pixels need
        // per-pixel mapping/masking, including when a client is zoomed. Bottom
        // rows still have a wide rectangular interior: do not remap thousands
        // of opaque pixels merely because the two small corner squares curve.
        var x = area.x * sc;
        while (x < area.right() * sc) {
            if (fast and source_w == content.w and source_h == content.h and x >= copy_left and x < copy_right) {
                const end = @min(area.right() * sc, copy_right);
                const from: usize = @intCast(sy * source_w * sc + x - content.x * sc);
                const to: usize = @intCast(y * s.stride + x);
                const len: usize = @intCast(end - x);
                @memcpy(s.pixels[to..][0..len], src[from..][0..len]);
                x = end;
                continue;
            }
            const alpha = bottomCoverage(frame, sc, radius, x, y);
            if (alpha != 0) {
                const sx = @max(0, @min(source_w * sc - 1, @divTrunc((x - content.x * sc) * source_w, content.w)));
                const pixel = src[@intCast(sy * source_w * sc + sx)];
                const to: usize = @intCast(y * s.stride + x);
                s.pixels[to] = if (alpha == 255) pixel else gfx.lerp(s.pixels[to], pixel, alpha);
            }
            x += 1;
        }
    }
}

test "bottom interior copies match scalar body mapping on changing patterned clients" {
    const std = @import("std");
    var source: [100 * 90 * 4]u32 = undefined;
    var pixels: [140 * 120 * 4]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| for (0..9) |iteration| {
        for (&source, 0..) |*p, i| p.* = @truncate((i + iteration * 117) *% 78113);
        for (&pixels, 0..) |*p, i| p.* = @truncate((i + iteration * 1331) *% 16713);
        const original = pixels;
        var s = gfx.Surface{ .pixels = &pixels, .width = 140, .height = 120, .stride = 140 * scale, .scale = scale };
        const frame = Rect{ .x = @as(i32, @intCast(iteration)) * 5 - 15, .y = 1, .w = 102, .h = 97 };
        const content = Rect{ .x = frame.x + 1, .y = 7, .w = 100, .h = 90 };
        if (iteration % 3 == 1) s.setClip(.{ .x = 9, .y = 84, .w = 89, .h = 13 });
        const source_w: i32 = if (iteration % 3 == 2) 50 else 100;
        const source_h: i32 = if (iteration % 3 == 2) 45 else 90;
        paintImpl(&s, frame, content, &source, source_w, source_h, false);
        const expected = pixels;
        pixels = original;
        paint(&s, frame, content, &source, source_w, source_h);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    };
}

fn bottomCoverage(r: Rect, sc: i32, radius: i32, x: i32, y: i32) u8 {
    const cy = r.bottom() * sc - radius;
    if (radius == 0 or y < cy) return 255;
    const left = r.x * sc + radius;
    const right = r.right() * sc - radius;
    if (x >= left and x < right) return 255;
    const cx = if (x < left) left else right;
    // 4x4 subpixel coverage, confined to the two small corner squares.
    var inside: u32 = 0;
    for ([_]i32{ 1, 3, 5, 7 }) |oy| for ([_]i32{ 1, 3, 5, 7 }) |ox| {
        const dx = (x - cx) * 8 + ox;
        const dy = (y - cy) * 8 + oy;
        if (dx * dx + dy * dy <= radius * radius * 64) inside += 1;
    };
    return @intCast((inside * 255 + 8) / 16);
}

test "body corners blend only app and backdrop, symmetric at 1x and 2x" {
    const std = @import("std");
    var source = [_]u32{0x202338} ** (76 * 66);
    var pixels: [100 * 100]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| {
        @memset(&pixels, 0xEE8844);
        var s = gfx.Surface{ .pixels = &pixels, .width = 50, .height = 50, .stride = 50 * scale, .scale = scale };
        const frame = Rect{ .x = 5, .y = 5, .w = 40, .h = 40 };
        const content = Rect{ .x = 6, .y = 11, .w = 38, .h = 33 };
        paint(&s, frame, content, &source, 38, 33);
        try std.testing.expectEqual(@as(u32, 0xEE8844), s.getPhysical(5 * scale, 44 * scale));
        try std.testing.expectEqual(@as(u32, 0x202338), s.getPhysical(25 * scale, 44 * scale));
        var blended: usize = 0;
        var y = 32 * scale;
        while (y < 45 * scale) : (y += 1) {
            var x = 5 * scale;
            while (x < 18 * scale) : (x += 1) {
                const c = s.getPhysical(x, y);
                try std.testing.expectEqual(c, s.getPhysical(50 * scale - 1 - x, y));
                if (c != 0xEE8844 and c != 0x202338) blended += 1;
                try std.testing.expect((c & 255) <= 0x44); // no pale undercoat
            }
        }
        try std.testing.expect(blended > 0);
        const expected = pixels;
        @memset(&pixels, 0xEE8844);
        s.setClip(.{ .x = 5, .y = 32, .w = 13, .h = 13 });
        paint(&s, frame, content, &source, 38, 33);
        for (0..@intCast(50 * scale)) |yy| for (0..@intCast(50 * scale)) |xx| {
            const in_clip = xx >= 5 * scale and xx < 18 * scale and yy >= 32 * scale and yy < 45 * scale;
            const i = yy * @as(usize, @intCast(50 * scale)) + xx;
            try std.testing.expectEqual(if (in_clip) expected[i] else @as(u32, 0xEE8844), pixels[i]);
        };
        s.resetClip();
        @memset(&pixels, 0xEE8844);
        paint(&s, frame, content, &source, 19, 16); // zoom path
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
}

test "offscreen body keeps source alignment and repeats edge colour into rim" {
    const std = @import("std");
    var source: [20 * 20]u32 = undefined;
    for (&source, 0..) |*p, i| p.* = @intCast(i);
    var pixels = [_]u32{0xEE8844} ** (30 * 40);
    const s = gfx.Surface{ .pixels = &pixels, .width = 30, .height = 40, .stride = 30 };
    const frame = Rect{ .x = -4, .y = 1, .w = 22, .h = 27 };
    const content = Rect{ .x = -3, .y = 7, .w = 20, .h = 20 };
    paint(&s, frame, content, &source, 20, 20);
    try std.testing.expectEqual(source[3], s.getPhysical(0, 7));
    try std.testing.expectEqual(source[19], s.getPhysical(17, 7));
    try std.testing.expectEqual(source[19 * 20 + 10], s.getPhysical(7, 27));
    try std.testing.expectEqual(@as(u32, 0xEE8844), s.getPhysical(18, 7));
}
