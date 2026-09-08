//! Allocation-free Inter coverage-atlas renderer. Atlas font data is licensed
//! under SIL OFL 1.1; see assets/fonts/OFL-Inter.txt. Renderer code follows the
//! repository license. tools/fontconv/desktop_font.py regenerates the atlas.
const data = @embedFile("inter-atlas.bin");

pub const Glyph = struct {
    pixels: []const u8,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    advance: i32,
};

pub fn glyph(c: u8, scale: i32) Glyph {
    return atlasGlyph(data, c, scale, 8);
}
fn atlasGlyph(atlas: []const u8, c: u8, scale: i32, max_scale: i32) Glyph {
    const code: usize = if (c >= 32 and c <= 126) c - 32 else '?' - 32;
    const size: usize = @intCast(@max(1, @min(max_scale, scale)) - 1);
    const p = (size * 95 + code) * 12;
    const offset = @as(usize, atlas[p]) | (@as(usize, atlas[p + 1]) << 8) | (@as(usize, atlas[p + 2]) << 16) | (@as(usize, atlas[p + 3]) << 24);
    const w: usize = atlas[p + 4];
    const h: usize = atlas[p + 5];
    return .{ .pixels = atlas[offset..][0 .. w * h], .width = @intCast(w), .height = @intCast(h), .x = @as(i8, @bitCast(atlas[p + 6])), .y = @as(i8, @bitCast(atlas[p + 7])), .advance = atlas[p + 8] };
}

pub fn blend(bg: u32, fg: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    var color: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        color |= (((bg >> shift & 255) * (255 - a) + (fg >> shift & 255) * a) / 255) << shift;
    }
    return color;
}

pub fn drawChar(target: anytype, c: u8, x: i32, y: i32, scale: i32, color: u32) void {
    paintGlyph(target, glyph(c, scale * target.scale), x, y, scale, color);
}
pub fn drawMono(target: anytype, c: u8, x: i32, y: i32, color: u32) void {
    paintGlyph(target, atlasGlyph(@embedFile("mono-atlas.bin"), c, target.scale, 2), x, y, 1, color);
}
fn paintGlyph(target: anytype, g: Glyph, x: i32, y: i32, scale: i32, color: u32) void {
    const backing = target.scale;
    const origin_x = x * backing + g.x;
    const origin_y = y * backing + g.y - scale * backing * 2;
    var left: i32 = 0;
    var top: i32 = 0;
    var right = target.width * backing;
    var bottom = target.height * backing;
    if (@hasField(@TypeOf(target.*), "clip")) {
        // Surface's default unbounded logical clip is 1<<30. Clamp before
        // backing-scale multiplication; Retina must not overflow that sentinel.
        left = @min(target.width, @max(0, target.clip.x)) * backing;
        top = @min(target.height, @max(0, target.clip.y)) * backing;
        right = @as(i32, @intCast(@max(0, @min(@as(i64, target.width), @as(i64, target.clip.x) + target.clip.w)))) * backing;
        bottom = @as(i32, @intCast(@max(0, @min(@as(i64, target.height), @as(i64, target.clip.y) + target.clip.h)))) * backing;
    }
    const row_end = @min(g.height, bottom - origin_y);
    const col_end = @min(g.width, right - origin_x);
    var row = @max(0, top - origin_y);
    while (row < row_end) : (row += 1) {
        const yy = origin_y + row;
        var col = @max(0, left - origin_x);
        while (col < col_end) : (col += 1) {
            const xx = origin_x + col;
            const a = g.pixels[@intCast(row * g.width + col)];
            if (a == 0) continue;
            target.putPhysical(xx, yy, blend(target.getPhysical(xx, yy), color, a));
        }
    }
}

pub fn drawText(target: anytype, str: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
    var xx = x;
    for (str) |c| {
        drawChar(target, c, xx, y, scale, color);
        xx += glyph(c, scale).advance;
    }
}

pub fn textWidth(str: []const u8, scale: i32) i32 {
    var width: i32 = 0;
    for (str) |c| width += glyph(c, scale).advance;
    return width;
}

test "glyph clipping preserves pixels and skips off-damage reads" {
    const std = @import("std");
    const Target = struct {
        const Self = @This();
        width: i32 = 80,
        height: i32 = 30,
        scale: i32,
        pixels: [80 * 30 * 4]u32 = [_]u32{0x223344} ** (80 * 30 * 4),
        reads: usize = 0,
        clip: struct { x: i32, y: i32, w: i32, h: i32 } = .{ .x = 0, .y = 0, .w = 1 << 30, .h = 1 << 30 },
        pub fn getPhysical(self: *Self, x: i32, y: i32) u32 {
            self.reads += 1;
            return self.pixels[@intCast(y * self.width * self.scale + x)];
        }
        pub fn putPhysical(self: *Self, x: i32, y: i32, color: u32) void {
            self.pixels[@intCast(y * self.width * self.scale + x)] = color;
        }
    };
    for ([_]i32{ 1, 2 }) |backing| {
        var target = Target{ .scale = backing };
        drawText(&target, "September", 1, 12, 2, 0xFFFFFF);
        const expected = target.pixels;
        target = .{ .scale = backing };
        target.clip = .{ .x = 7, .y = 9, .w = 11, .h = 8 };
        drawText(&target, "September", 1, 12, 2, 0xFFFFFF);
        for (0..@intCast(30 * backing)) |y| for (0..@intCast(80 * backing)) |x| {
            const inside = x >= 7 * backing and x < 18 * backing and y >= 9 * backing and y < 17 * backing;
            const index = y * @as(usize, @intCast(80 * backing)) + x;
            try std.testing.expectEqual(if (inside) expected[index] else @as(u32, 0x223344), target.pixels[index]);
        };
        target.reads = 0;
        drawText(&target, "Outside damage", 100, 100, 2, 0xFFFFFF);
        try std.testing.expectEqual(@as(usize, 0), target.reads);
    }
}
