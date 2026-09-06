//! A small boot splash drawn before the memory allocator is available.
//! Diagnostics continue to serial; exceptions reclaim and replay the console.
const framebuffer = @import("framebuffer.zig");
const font = @import("font.zig");

fn rgb(f: *const framebuffer.Fb, color: u32) u32 {
    return f.rgb(@truncate(color >> 16), @truncate(color >> 8), @truncate(color));
}
fn mix(a: u32, b: u32, t: u32) u32 {
    var c: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        const av = (a >> shift) & 255;
        const bv = (b >> shift) & 255;
        c |= ((av * (255 - t) + bv * t) / 255) << shift;
    }
    return c;
}
fn text(f: *const framebuffer.Fb, str: []const u8, x: usize, y: usize, scale: usize, color: u32) void {
    for (str, 0..) |c, i| {
        const g = font.glyph(c);
        for (0..8) |row| for (0..8) |col| {
            if (g[row] & (@as(u8, 0x80) >> @intCast(col)) != 0) f.fillRect(x + (i * 8 + col) * scale, y + row * scale, scale, scale, rgb(f, color));
        };
    }
}
pub fn show() void {
    const f = framebuffer.get() orelse return;
    if (f.width < 640 or f.height < 480) return;
    for (0..f.height) |y| {
        const t: u32 = @intCast(y * 255 / f.height);
        f.fillRect(0, y, f.width, 1, rgb(f, mix(0x332767, 0xDF7493, t)));
    }
    const cx: i32 = @intCast(f.width / 2);
    const cy: i32 = @as(i32, @intCast(f.height / 2)) - 50;
    var y: i32 = -62;
    while (y <= 62) : (y += 1) {
        var x: i32 = -62;
        while (x <= 62) : (x += 1) {
            if (x * x + y * y < 60 * 60) {
                const t: u32 = @intCast(@divTrunc((y + 62) * 255, 124));
                f.putPixel(@intCast(cx + x), @intCast(cy + y), rgb(f, mix(0xFFE5A0, 0xFF865F, t)));
            }
            const leaf_x = x - 23;
            const leaf_y = y + 50;
            if (leaf_x * leaf_x + leaf_y * leaf_y * 3 < 18 * 18) f.putPixel(@intCast(cx + x), @intCast(cy + y - 17), rgb(f, 0x8CE5B8));
        }
    }
    text(f, "Orange OS", f.width / 2 - 108, f.height / 2 + 40, 3, 0xFFF6F4);
    text(f, "A brighter place to make things.", f.width / 2 - 124, f.height / 2 + 86, 1, 0xF0CFEB);
    progress(1);
}
pub fn progress(step: usize) void {
    const f = framebuffer.get() orelse return;
    if (f.width < 640 or f.height < 480) return;
    const x = f.width / 2 - 100;
    const y = f.height / 2 + 124;
    f.fillRect(x, y, 200, 4, rgb(f, 0xA875A4));
    f.fillRect(x, y, @as(usize, @min(step, 4)) * 50, 4, rgb(f, 0xFFE3B4));
}
