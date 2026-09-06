//! Shared SVG-derived desktop artwork. Rendered at native backing scale.
pub const gfx = @import("gfx");
pub const Surface = gfx.Surface;
pub const Rect = gfx.Rect;
const font = @import("typography");
pub const Icon = enum { welcome, terminal, clock, about, windows, appearance, files, trash, chevron_left, chevron_right, chevron_up, document, brand, controls, close, minimize, maximize, pointer };
pub const Button = struct { id: u32, rect: Rect };
/// Capture starts on press; moving onto a button while held cannot activate it.
pub const Pointer = struct {
    hover: u32 = 0,
    pressed: u32 = 0,
    down: bool = false,
    pub fn update(self: *Pointer, x: i32, y: i32, buttons: u8, targets: []const Button) u32 {
        var hit: u32 = 0;
        for (targets) |t| if (t.rect.contains(x, y)) {
            hit = t.id;
            break;
        };
        const down = buttons & 1 != 0;
        self.hover = hit;
        if (down and !self.down) self.pressed = hit;
        const action = if (!down and self.down and self.pressed == hit) hit else 0;
        if (!down) self.pressed = 0;
        self.down = down;
        return action;
    }
};

pub fn surface(win: anytype) Surface {
    return .{ .pixels = win.pixels, .width = win.width, .height = win.height, .stride = win.stride, .scale = win.scale };
}

pub fn gradient(s: *Surface, r: Rect, radius: i32, top: u32, bottom: u32) void {
    const clip = s.clip;
    defer s.setClip(clip);
    var y = @max(r.y, clip.y);
    while (y < @min(r.bottom(), clip.bottom())) : (y += 1) {
        s.setClip(Rect.intersect(clip, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }));
        s.rounded(r, radius, gfx.lerp(top, bottom, @intCast(@divTrunc((y - r.y) * 255, @max(1, r.h - 1)))), 255);
    }
}

const atlas = @embedFile("icons.bin");
fn u16at(at: usize) usize {
    return @as(usize, atlas[at]) | (@as(usize, atlas[at + 1]) << 8);
}
fn u32at(at: usize) usize {
    return u16at(at) | (u16at(at + 2) << 16);
}
fn spritePixel(offset: usize, width: usize, x: usize, y: usize) u32 {
    const p = offset + (y * width + x) * 4;
    return (@as(u32, atlas[p + 3]) << 24) | (@as(u32, atlas[p]) << 16) | (@as(u32, atlas[p + 1]) << 8) | atlas[p + 2];
}
fn mix(a: u32, b: u32, t: u8) u32 {
    const alpha = ((a >> 24) * (255 - @as(u32, t)) + (b >> 24) * t) / 255;
    return (alpha << 24) | gfx.lerp(a, b, t);
}
/// SVG-derived RGBA sprites; sample at backing resolution, with
/// premultiplied-alpha interpolation so transparent edges have no dark halo.
pub fn icon(s: *const Surface, kind: Icon, x: i32, y: i32, size: i32) void {
    if (size <= 0) return;
    const h = @as(usize, @intFromEnum(kind)) * 8;
    const width = u16at(h);
    const height = u16at(h + 2);
    const offset = u32at(h + 4);
    const r = Rect.intersect(Rect.intersect(.{ .x = x, .y = y, .w = size, .h = size }, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
    const physical = size * s.scale;
    var yy = r.y * s.scale;
    while (yy < r.bottom() * s.scale) : (yy += 1) {
        const sy: usize = @intCast(@max(0, @divTrunc((2 * (yy - y * s.scale) + 1) * @as(i32, @intCast(height)) * 128, physical) - 128));
        const y0 = @min(height - 1, sy >> 8);
        const y1 = @min(height - 1, y0 + 1);
        var xx = r.x * s.scale;
        while (xx < r.right() * s.scale) : (xx += 1) {
            const sx: usize = @intCast(@max(0, @divTrunc((2 * (xx - x * s.scale) + 1) * @as(i32, @intCast(width)) * 128, physical) - 128));
            const x0 = @min(width - 1, sx >> 8);
            const x1 = @min(width - 1, x0 + 1);
            const top = mix(spritePixel(offset, width, x0, y0), spritePixel(offset, width, x1, y0), @truncate(sx));
            const bottom = mix(spritePixel(offset, width, x0, y1), spritePixel(offset, width, x1, y1), @truncate(sx));
            const p = mix(top, bottom, @truncate(sy));
            const alpha = p >> 24;
            if (alpha == 0) continue;
            const bg = s.getPhysical(xx, yy);
            const red: u32 = @min(255, ((p >> 16) & 255) + ((bg >> 16) & 255) * (255 - alpha) / 255);
            const green: u32 = @min(255, ((p >> 8) & 255) + ((bg >> 8) & 255) * (255 - alpha) / 255);
            const blue: u32 = @min(255, (p & 255) + (bg & 255) * (255 - alpha) / 255);
            s.putPhysical(xx, yy, (red << 16) | (green << 8) | blue);
        }
    }
}

pub fn label(s: *const Surface, str: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
    font.drawText(s, str, x, y, scale, color);
}

test "every SVG sprite renders at 1x and 2x with clipped alpha edges" {
    const std = @import("std");
    var pixels: [128 * 128]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| {
        var s = Surface{ .pixels = &pixels, .width = 64, .height = 64, .stride = 64 * scale, .scale = scale };
        inline for (std.meta.tags(Icon)) |kind| {
            @memset(&pixels, 0xCACACA);
            s.setClip(.{ .x = 8, .y = 8, .w = 42, .h = 42 });
            icon(&s, kind, 2, 2, 52);
            var changed: usize = 0;
            for (0..@intCast(64 * scale)) |y| for (0..@intCast(64 * scale)) |x| {
                const pixel = pixels[y * @as(usize, @intCast(s.stride)) + x];
                if (!s.clip.contains(@divTrunc(@as(i32, @intCast(x)), scale), @divTrunc(@as(i32, @intCast(y)), scale))) {
                    try std.testing.expectEqual(@as(u32, 0xCACACA), pixel);
                } else if (pixel != 0xCACACA) changed += 1;
            };
            try std.testing.expect(changed > 0);
        }
    }
}

test "pointer only activates the originally pressed target" {
    const std = @import("std");
    const buttons = [_]Button{ .{ .id = 1, .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }, .{ .id = 2, .rect = .{ .x = 40, .y = 10, .w = 20, .h = 20 } } };
    var p: Pointer = .{};
    try std.testing.expectEqual(@as(u32, 0), p.update(0, 0, 1, &buttons));
    try std.testing.expectEqual(@as(u32, 0), p.update(15, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 0), p.update(45, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 1), p.update(15, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 0), p.update(-100, -100, 0, &buttons));
}
