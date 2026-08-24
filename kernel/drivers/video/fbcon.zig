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

/// Minimal ANSI escape handling.
///
/// Userland writes colour codes, and a console that prints them literally is
/// worse than one with no colour at all. Only what programs here actually
/// emit is supported: SGR colour/reset, erase-display, and cursor-home.
const EscState = enum { none, esc, csi };

var esc_state: EscState = .none;
var esc_params: [8]u32 = undefined;
var esc_param_count: usize = 0;
var esc_current: u32 = 0;
var esc_has_digit: bool = false;

fn sgr256(index: u32) u32 {
    const f = fb orelse return 0;
    // The 6x6x6 colour cube occupies 16..231; the grey ramp runs 232..255.
    if (index >= 16 and index <= 231) {
        const i = index - 16;
        const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
        return f.rgb(levels[(i / 36) % 6], levels[(i / 6) % 6], levels[i % 6]);
    }
    if (index >= 232) {
        const v: u8 = @intCast(8 + (index - 232) * 10);
        return f.rgb(v, v, v);
    }
    return switch (index) {
        1, 9 => f.rgb(0xE0, 0x50, 0x40),
        2, 10 => f.rgb(0x60, 0xC0, 0x60),
        3, 11 => f.rgb(0xE0, 0xB0, 0x40),
        4, 12 => f.rgb(0x60, 0x90, 0xE0),
        5, 13 => f.rgb(0xC0, 0x70, 0xD0),
        6, 14 => f.rgb(0x50, 0xC0, 0xC0),
        else => theme.fg,
    };
}

fn applySgr() void {
    if (esc_param_count == 0) {
        resetColor();
        return;
    }
    var i: usize = 0;
    while (i < esc_param_count) : (i += 1) {
        const p = esc_params[i];
        if (p == 0) {
            resetColor();
        } else if (p == 38 and i + 2 < esc_param_count and esc_params[i + 1] == 5) {
            // 38;5;N — 256-colour foreground.
            setColor(sgr256(esc_params[i + 2]));
            i += 2;
        } else if (p >= 30 and p <= 37) {
            setColor(sgr256(p - 30));
        } else if (p >= 90 and p <= 97) {
            setColor(sgr256(p - 90 + 8));
        }
    }
}

fn pushParam() void {
    if (esc_param_count < esc_params.len) {
        esc_params[esc_param_count] = esc_current;
        esc_param_count += 1;
    }
    esc_current = 0;
    esc_has_digit = false;
}

/// Returns true if the byte was consumed as part of an escape sequence.
fn handleEscape(c: u8) bool {
    switch (esc_state) {
        .none => {
            if (c != 0x1B) return false;
            esc_state = .esc;
            return true;
        },
        .esc => {
            if (c == '[') {
                esc_state = .csi;
                esc_param_count = 0;
                esc_current = 0;
                esc_has_digit = false;
            } else {
                esc_state = .none; // sequence we do not implement
            }
            return true;
        },
        .csi => {
            if (c >= '0' and c <= '9') {
                esc_current = esc_current * 10 + (c - '0');
                esc_has_digit = true;
                return true;
            }
            if (c == ';') {
                pushParam();
                return true;
            }
            if (esc_has_digit) pushParam();

            switch (c) {
                'm' => applySgr(),
                'J' => clearScreen(),
                'H' => home(),
                else => {},
            }
            esc_state = .none;
            return true;
        },
    }
}

fn clearScreen() void {
    const f = fb orelse return;
    f.clear(color_bg);
    cx = 0;
    cy = 0;
}

fn home() void {
    cx = 0;
    cy = 0;
}

pub fn writeByte(c: u8) void {
    const f = fb orelse return;

    if (handleEscape(c)) return;

    switch (c) {
        '\n' => {
            cx = 0;
            cy += 1;
        },
        '\r' => cx = 0,
        '\t' => cx = (cx + 4) & ~@as(usize, 3),
        // Backspace: move left one cell and blank it, so the shell's line
        // editing erases visibly rather than leaving the old glyph behind.
        0x08 => {
            if (cx > 0) {
                cx -= 1;
                f.fillRect(MARGIN + cx * CELL_W, MARGIN + cy * CELL_H, CELL_W, CELL_H, color_bg);
            }
        },
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

var suspended: bool = false;

/// Stop drawing to the framebuffer. Called when a compositor takes the screen;
/// two things painting the same pixels is worse than one.
pub fn suspendOutput() void {
    suspended = true;
}

pub fn resumeOutput() void {
    suspended = false;
}

/// Take the screen back unconditionally and clear it.
///
/// For the panic path only. Once a compositor owns the framebuffer the kernel
/// console stands down, which means a panic after boot would print to a serial
/// port that most real machines do not have - a silent freeze, and the worst
/// possible failure mode for hardware bring-up. A dead kernel has no reason to
/// be polite about who owns the screen.
pub fn reclaim() void {
    if (fb == null) return;
    suspended = false;
    esc_state = .none;
    color_fg = theme.fg;
    color_bg = theme.bg;
    clearScreen();
}

pub fn isReady() bool {
    return fb != null and !suspended;
}

pub fn dimensions() struct { cols: usize, rows: usize } {
    return .{ .cols = cols, .rows = rows };
}
