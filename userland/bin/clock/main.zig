//! clock — a graphical client.
//!
//! Asks Peel for a window, then renders into the shared buffer and commits
//! damage. Peel composites it without ever knowing what the content means.

const pulp = @import("pulp");
const libpeel = @import("libpeel");
const glyphs = @import("glyphs.zig");

const BG: u32 = 0x141018;
const FG: u32 = 0xEAE0D5;
const ACCENT: u32 = 0xFF8C1A;
const DIM: u32 = 0x6A5A4A;

fn drawChar(w: *const libpeel.Window, c: u8, x: i32, y: i32, scale: i32, color: u32) void {
    const g = glyphs.glyph(c);
    var row: i32 = 0;
    while (row < 8) : (row += 1) {
        const bits = g[@intCast(row)];
        var col: i32 = 0;
        while (col < 8) : (col += 1) {
            if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
            w.fill(x + col * scale, y + row * scale, scale, scale, color);
        }
    }
}

fn drawText(w: *const libpeel.Window, text: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
    var cx = x;
    for (text) |c| {
        drawChar(w, c, cx, y, scale, color);
        cx += 8 * scale;
    }
}

fn fmtNum(buf: []u8, value: u64, width: usize) []const u8 {
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        digits[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[n] = '0' + @as(u8, @intCast(v % 10));
            n += 1;
        }
    }
    var out: usize = 0;
    while (out + n < width) : (out += 1) buf[out] = '0';
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[out] = digits[n - 1 - i];
        out += 1;
    }
    return buf[0..out];
}

export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("clock", 300, 120, 140, 420) catch {
        pulp.puts("clock: no display server\n");
        pulp.exit(1);
    };

    pulp.print("clock: got window {d} ({d}x{d})\n", .{ win.id, win.width, win.height });

    var frames: u64 = 0;
    var last_shown: u64 = 0xFFFF_FFFF;

    while (true) {
        const ms = pulp.uptimeMs();
        const secs = ms / 1000;

        // Only repaint when the displayed value actually changes. Committing
        // every loop would make Peel recomposite for no reason.
        if (secs != last_shown) {
            last_shown = secs;
            frames += 1;

            win.clear(BG);
            win.fill(0, 0, win.width, 3, ACCENT);

            var buf: [32]u8 = undefined;
            const h = secs / 3600;
            const m = (secs % 3600) / 60;
            const sec = secs % 60;

            var text: [16]u8 = undefined;
            var n: usize = 0;
            const hs = fmtNum(&buf, h, 2);
            @memcpy(text[n .. n + hs.len], hs);
            n += hs.len;
            text[n] = ':';
            n += 1;
            const msx = fmtNum(&buf, m, 2);
            @memcpy(text[n .. n + msx.len], msx);
            n += msx.len;
            text[n] = ':';
            n += 1;
            const ss = fmtNum(&buf, sec, 2);
            @memcpy(text[n .. n + ss.len], ss);
            n += ss.len;

            drawText(&win, text[0..n], 40, 30, 4, FG);
            drawText(&win, "uptime since boot", 40, 80, 1, DIM);

            var fb2: [32]u8 = undefined;
            const fs = fmtNum(&fb2, frames, 1);
            drawText(&win, fs, win.width - 40, 96, 1, DIM);

            win.commitAll();
        }

        pulp.sleepMs(100);
    }
}
