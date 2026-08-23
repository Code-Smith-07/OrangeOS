//! Framebuffer text console.
//!
//! Renders the 8x8 font at 2x scale (16x16 cells) so boot output stays legible
//! at high resolutions. Scrolls by moving scanlines up when the cursor passes
//! the bottom row.

const framebuffer = @import("framebuffer.zig");
const font = @import("font.zig");

const SCALE = 2;
/// Leading between text rows. Without it, 16px glyphs in 16px cells touch
/// vertically and descenders collide with the next line's caps.
const LEADING = 5;
const CELL_W = font.WIDTH * SCALE;
const CELL_H = font.HEIGHT * SCALE + LEADING;
const MARGIN = 20;

pub const Theme = struct {
    bg: u32,
    fg: u32,
    accent: u32,
    dim: u32,
};

var fb: ?*const framebuffer.Fb = null;
var cols: usize = 0;
var rows: usize = 0;
var cx: usize = 0;
var cy: usize = 0;
var color_fg: u32 = 0;
var color_bg: u32 = 0;
pub var theme: Theme = undefined;

pub fn init() bool {
    const f = framebuffer.get() orelse return false;
    fb = f;

    theme = .{
        .bg = f.rgb(0x10, 0x0B, 0x06), // near-black, warm
        .fg = f.rgb(0xEA, 0xE0, 0xD5), // warm off-white
        .accent = f.rgb(0xFF, 0x8C, 0x1A), // orange
        .dim = f.rgb(0x8A, 0x7A, 0x6A), // muted
    };

    color_fg = theme.fg;
    color_bg = theme.bg;

    cols = (f.width - MARGIN * 2) / CELL_W;
    rows = (f.height - MARGIN * 2) / CELL_H;
    cx = 0;
    cy = 0;

    f.clear(theme.bg);
    return true;
}

pub fn setColor(fg: u32) void {
    color_fg = fg;
}

pub fn resetColor() void {
    color_fg = theme.fg;
}

fn drawGlyph(f: *const framebuffer.Fb, c: u8, px: usize, py: usize) void {
    const g = font.glyph(c);
    var row: usize = 0;
    while (row < font.HEIGHT) : (row += 1) {
        const bits = g[row];
        var col: usize = 0;
        while (col < font.WIDTH) : (col += 1) {
            const on = (bits & (@as(u8, 0x80) >> @intCast(col))) != 0;
            if (!on) continue;
            // Expand one font pixel into a SCALE x SCALE block.
            var sy: usize = 0;
            while (sy < SCALE) : (sy += 1) {
                var sx: usize = 0;
                while (sx < SCALE) : (sx += 1) {
                    f.putPixel(px + col * SCALE + sx, py + row * SCALE + sy, color_fg);
                }
            }
        }
    }
}

fn scroll(f: *const framebuffer.Fb) void {
    const top = MARGIN;
    const line_bytes = f.pitch * CELL_H;
    const visible_bytes = f.pitch * (rows * CELL_H);

    // Move every row up by one cell height.
    var i: usize = 0;
    while (i < visible_bytes - line_bytes) : (i += 1) {
        f.base[top * f.pitch + i] = f.base[top * f.pitch + i + line_bytes];
    }
    // Clear the freed bottom row.
    f.fillRect(0, top + (rows - 1) * CELL_H, f.width, CELL_H, color_bg);
}

pub fn writeByte(c: u8) void {
    const f = fb orelse return;

    switch (c) {
        '\n' => {
            cx = 0;
            cy += 1;
        },
        '\r' => cx = 0,
        '\t' => cx = (cx + 4) & ~@as(usize, 3),
        else => {
            if (cx >= cols) {
                cx = 0;
                cy += 1;
            }
            if (cy >= rows) {
                scroll(f);
                cy = rows - 1;
            }
            drawGlyph(f, c, MARGIN + cx * CELL_W, MARGIN + cy * CELL_H);
            cx += 1;
        },
    }

    if (cy >= rows) {
        scroll(f);
        cy = rows - 1;
    }
}

pub fn write(s: []const u8) void {
    for (s) |c| writeByte(c);
}

pub fn isReady() bool {
    return fb != null;
}

pub fn dimensions() struct { cols: usize, rows: usize } {
    return .{ .cols = cols, .rows = rows };
}
