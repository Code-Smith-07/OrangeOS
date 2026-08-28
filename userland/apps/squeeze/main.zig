//! Squeeze — the Orange OS terminal emulator.
//!
//! Owns a PTY, starts Juice on its slave end, and paints the resulting text
//! into a Peel window. The shell is unaware of any of this: it reads fd 0 and
//! writes fd 1 exactly as it does on a serial line.
//!
//! Loop: drain the PTY into a character grid, take key events from Peel and
//! push them into the PTY, repaint the rows that changed.

const pulp = @import("pulp");
const libpeel = @import("libpeel");
const proto = libpeel.proto;
const glyphs = @import("glyphs.zig");
const keymap = @import("keymap.zig");

const CELL_W: i32 = 8;
const CELL_H: i32 = 14;
const COLS: i32 = 76;
const ROWS: i32 = 26;
const PAD: i32 = 6;

const WIN_W: i32 = COLS * CELL_W + PAD * 2;
const WIN_H: i32 = ROWS * CELL_H + PAD * 2;

const BG: u32 = 0x0F0C0A;
const FG: u32 = 0xD8CEC4;
const ACCENT: u32 = 0xFF8C1A;
const CURSOR: u32 = 0xFF8C1A;

const Cell = struct {
    ch: u8 = ' ',
    color: u32 = FG,
};

var grid: [ROWS][COLS]Cell = undefined;
var dirty: [ROWS]bool = undefined;

var cx: i32 = 0;
var cy: i32 = 0;
var cur_color: u32 = FG;

var shift_down: bool = false;

// ── Grid ────────────────────────────────────────────────────────────────────

fn clearGrid() void {
    var y: i32 = 0;
    while (y < ROWS) : (y += 1) {
        var x: i32 = 0;
        while (x < COLS) : (x += 1) grid[@intCast(y)][@intCast(x)] = .{};
        dirty[@intCast(y)] = true;
    }
    cx = 0;
    cy = 0;
}

fn scroll() void {
    var y: i32 = 0;
    while (y < ROWS - 1) : (y += 1) {
        grid[@intCast(y)] = grid[@intCast(y + 1)];
        dirty[@intCast(y)] = true;
    }
    var x: i32 = 0;
    while (x < COLS) : (x += 1) grid[@intCast(ROWS - 1)][@intCast(x)] = .{};
    dirty[@intCast(ROWS - 1)] = true;
    cy = ROWS - 1;
}

fn newline() void {
    cx = 0;
    cy += 1;
    if (cy >= ROWS) scroll();
}

fn putChar(c: u8) void {
    if (cx >= COLS) newline();
    grid[@intCast(cy)][@intCast(cx)] = .{ .ch = c, .color = cur_color };
    dirty[@intCast(cy)] = true;
    cx += 1;
}

// ── Escape sequences ────────────────────────────────────────────────────────
//
// Only what Juice emits: SGR colour, erase-display, and cursor-home. Anything
// else is consumed and ignored rather than printed as garbage.

const EscState = enum { none, esc, csi };
var esc_state: EscState = .none;
var esc_params: [8]u32 = undefined;
var esc_count: usize = 0;
var esc_cur: u32 = 0;
var esc_digit: bool = false;

fn sgrColor(index: u32) u32 {
    if (index >= 16 and index <= 231) {
        const i = index - 16;
        const levels = [_]u32{ 0, 95, 135, 175, 215, 255 };
        return (levels[(i / 36) % 6] << 16) | (levels[(i / 6) % 6] << 8) | levels[i % 6];
    }
    if (index >= 232) {
        const v: u32 = 8 + (index - 232) * 10;
        return (v << 16) | (v << 8) | v;
    }
    return switch (index) {
        1, 9 => 0xE05040,
        2, 10 => 0x60C060,
        3, 11 => 0xE0B040,
        4, 12 => 0x6090E0,
        5, 13 => 0xC070D0,
        6, 14 => 0x50C0C0,
        else => FG,
    };
}

fn applySgr() void {
    if (esc_count == 0) {
        cur_color = FG;
        return;
    }
    var i: usize = 0;
    while (i < esc_count) : (i += 1) {
        const p = esc_params[i];
        if (p == 0) {
            cur_color = FG;
        } else if (p == 38 and i + 2 < esc_count and esc_params[i + 1] == 5) {
            cur_color = sgrColor(esc_params[i + 2]);
            i += 2;
        } else if (p >= 30 and p <= 37) {
            cur_color = sgrColor(p - 30);
        }
    }
}

fn pushParam() void {
    if (esc_count < esc_params.len) {
        esc_params[esc_count] = esc_cur;
        esc_count += 1;
    }
    esc_cur = 0;
    esc_digit = false;
}

/// Feed one byte of shell output into the terminal.
fn feed(c: u8) void {
    switch (esc_state) {
        .none => {
            switch (c) {
                0x1B => esc_state = .esc,
                '\n' => newline(),
                '\r' => cx = 0,
                8 => {
                    // Backspace moves left; the shell sends "\b \b" to erase.
                    if (cx > 0) cx -= 1;
                },
                '\t' => {
                    cx = (cx + 4) & ~@as(i32, 3);
                    if (cx >= COLS) newline();
                },
                else => {
                    if (c >= 0x20 and c < 0x7F) putChar(c);
                },
            }
        },
        .esc => {
            if (c == '[') {
                esc_state = .csi;
                esc_count = 0;
                esc_cur = 0;
                esc_digit = false;
            } else {
                esc_state = .none;
            }
        },
        .csi => {
            if (c >= '0' and c <= '9') {
                esc_cur = esc_cur * 10 + (c - '0');
                esc_digit = true;
                return;
            }
            if (c == ';') {
                pushParam();
                return;
            }
            if (esc_digit) pushParam();
            switch (c) {
                'm' => applySgr(),
                'J' => clearGrid(),
                'H' => {
                    cx = 0;
                    cy = 0;
                },
                else => {},
            }
            esc_state = .none;
        },
    }
}

// ── Painting ────────────────────────────────────────────────────────────────

var win: libpeel.Window = undefined;

fn drawGlyph(c: u8, px: i32, py: i32, color: u32) void {
    const g = glyphs.glyph(c);
    var row: i32 = 0;
    while (row < 8) : (row += 1) {
        const bits = g[@intCast(row)];
        var col: i32 = 0;
        while (col < 8) : (col += 1) {
            if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
            win.put(px + col, py + row, color);
        }
    }
}

var last_cursor_x: i32 = -1;
var last_cursor_y: i32 = -1;

fn paint() void {
    // Repaint the cursor's old row too, so the previous block is erased.
    if (last_cursor_y >= 0 and last_cursor_y < ROWS) dirty[@intCast(last_cursor_y)] = true;
    dirty[@intCast(cy)] = true;

    var y: i32 = 0;
    var top: i32 = -1;
    var bottom: i32 = -1;

    while (y < ROWS) : (y += 1) {
        if (!dirty[@intCast(y)]) continue;
        dirty[@intCast(y)] = false;
        if (top < 0) top = y;
        bottom = y;

        const py = PAD + y * CELL_H;
        win.fill(0, py, win.width, CELL_H, BG);

        var x: i32 = 0;
        while (x < COLS) : (x += 1) {
            const cell = grid[@intCast(y)][@intCast(x)];
            if (cell.ch == ' ') continue;
            drawGlyph(cell.ch, PAD + x * CELL_W, py + 3, cell.color);
        }
    }

    // Block cursor.
    win.fill(PAD + cx * CELL_W, PAD + cy * CELL_H + 2, CELL_W, CELL_H - 3, CURSOR);
    last_cursor_x = cx;
    last_cursor_y = cy;

    if (top < 0) return;
    // Commit only the band of rows that changed.
    win.commit(0, PAD + top * CELL_H, win.width, (bottom - top + 1) * CELL_H);
}

// ── Entry ───────────────────────────────────────────────────────────────────

export fn _start() callconv(.c) noreturn {
    clearGrid();

    win = libpeel.createWindow("Squeeze - juice", WIN_W, WIN_H, 60, 60) catch {
        pulp.puts("squeeze: no display server\n");
        pulp.exit(1);
    };
    win.clear(BG);
    win.commitAll();

    const pty = pulp.ptyCreate() catch {
        pulp.puts("squeeze: cannot create a pty\n");
        pulp.exit(1);
    };

    const shell = pulp.spawnPty("/bin/juice", pty) catch {
        pulp.puts("squeeze: cannot start the shell\n");
        pulp.exit(1);
    };
    pulp.print("squeeze: window {d}, shell pid {d}\n", .{ win.id, shell });


    var out: [512]u8 = undefined;
    var msg: [256]u8 = undefined;

    while (true) {
        var did_work = false;

        // Shell output into the grid.
        const n = pulp.ptyRead(pty, &out);
        if (n > 0) {
            var i: usize = 0;
            while (i < n) : (i += 1) feed(out[i]);
            did_work = true;

        }

        // Key events from Peel into the shell's stdin.
        while (true) {
            const m = pulp.portRecvMsg(win.reply, &msg, false) catch break;
            if (m.len == 0) break;
            if (m.opcode != proto.Op.input) continue;
            if (m.len < @sizeOf(proto.Input)) continue;

            const ev: *align(1) const proto.Input = @ptrCast(&msg);
            if (ev.kind != pulp.EV_KEY) continue;

            const pressed = ev.value & 1 != 0;
            if (ev.code == keymap.LSHIFT or ev.code == keymap.RSHIFT) {
                shift_down = pressed;
                continue;
            }
            if (!pressed) continue;

            const ch = keymap.translate(ev.code, shift_down);
            if (ch == 0) continue;

            var one = [_]u8{ch};
            _ = pulp.ptyWrite(pty, one[0..1]);
            did_work = true;
        }

        // Painting is not a clock. The old unconditional call marked the
        // cursor row dirty on every 16 ms poll and sent a commit even when the
        // terminal was completely unchanged. Peel then did real compositing
        // work for false damage. Repaint only after output or input changed
        // terminal state; the next shell echo moves the cursor as usual.
        if (did_work) paint();

        // Idle politely when neither side has anything to say.
        if (!did_work) pulp.sleepMs(16);
    }
}
