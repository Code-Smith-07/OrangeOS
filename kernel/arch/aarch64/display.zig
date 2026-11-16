//! The picture on screen during the first Arm stage.
//!
//! The kernel draws into its own memory with plain writes, then asks the
//! virtual GPU (virtio_gpu.zig) to show it. Nothing traps to the host while
//! drawing, so drawing is as fast as the processor.

const font = @import("../../drivers/video/font.zig");
const gpu = @import("virtio_gpu.zig");

pub const WIDTH = 1280;
pub const HEIGHT = 800;
const CANVAS: u32 = 0x14161C;

/// One pixel is 0x00RRGGBB.
pub var pixels: [WIDTH * HEIGHT]u32 align(4096) = undefined;

/// True when a virtual GPU was found and now shows `pixels`.
pub fn init(transport_physical: u64) bool {
    return gpu.init(transport_physical, @intFromPtr(&pixels), WIDTH, HEIGHT);
}

/// Put what has been drawn on the screen.
pub fn present() bool {
    return gpu.present();
}

fn fill(x: usize, y: usize, w: usize, h: usize, color: u32) void {
    var yy = y;
    while (yy < @min(y + h, HEIGHT)) : (yy += 1) {
        @memset(pixels[yy * WIDTH + x ..][0 .. @min(x + w, WIDTH) - x], color);
    }
}

fn text(str: []const u8, x: usize, y: usize, scale: usize, color: u32) void {
    for (str, 0..) |c, i| {
        const g = font.glyph(c);
        for (0..8) |row| for (0..8) |col| {
            if (g[row] & (@as(u8, 0x80) >> @intCast(col)) != 0) fill(x + (i * 8 + col) * scale, y + row * scale, scale, scale, color);
        };
    }
}

fn centred(str: []const u8, y: usize, scale: usize, color: u32) void {
    text(str, (WIDTH - str.len * 8 * scale) / 2, y, scale, color);
}

/// The boot picture: a solid dark canvas, one orange with a highlight where
/// the light falls on it (top left), a leaf, the name and one status line.
pub fn splash(status: []const u8) void {
    const orange: u32 = 0xFF8A1F;
    const shade: u32 = 0xE06A00;
    const shine: u32 = 0xFFC078;
    const leaf: u32 = 0x3DA55C;
    fill(0, 0, WIDTH, HEIGHT, CANVAS);

    const cx: i32 = WIDTH / 2;
    const cy: i32 = HEIGHT / 2 - 70;
    var y: i32 = -90;
    while (y <= 90) : (y += 1) {
        var x: i32 = -90;
        while (x <= 90) : (x += 1) {
            const px: usize = @intCast(cx + x);
            const py: usize = @intCast(cy + y);
            if (x * x + y * y < 80 * 80) {
                // Same hue throughout: lit towards the top left, deeper
                // towards the bottom right, a small bright reflection.
                const lx = x + 30;
                const ly = y + 34;
                var c = orange;
                if ((x + 16) * (x + 16) + (y + 18) * (y + 18) > 74 * 74) c = shade;
                if (lx * lx + ly * ly < 15 * 15) c = shine;
                pixels[py * WIDTH + px] = c;
            }
            const leaf_x = x - 26;
            const leaf_y = y + 84;
            if (leaf_x * leaf_x + leaf_y * leaf_y * 4 < 24 * 24) pixels[py * WIDTH + px] = leaf;
        }
    }
    centred("Orange OS", HEIGHT / 2 + 50, 4, 0xF4F4F6);
    centred("Arm64 native", HEIGHT / 2 + 100, 2, orange);
    centred(status, HEIGHT / 2 + 140, 1, 0x9A9CA6);
}

/// For the boot check: how many pixels are not background.
pub fn drawnPixels() usize {
    var n: usize = 0;
    // By reference: `for (pixels)` would copy all 4 MB onto the stack first.
    for (&pixels) |*p| {
        if (p.* != CANVAS) n += 1;
    }
    return n;
}
