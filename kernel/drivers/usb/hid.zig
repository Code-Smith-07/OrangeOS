//! USB HID boot protocol.
//!
//! Boot protocol is the small, fixed report format a keyboard or mouse must
//! support so firmware can use it without parsing a report descriptor. It is
//! exactly what is wanted here: eight bytes for a keyboard, three or four for
//! a mouse, with no negotiation.
//!
//! Reports carry HID usage IDs, but the rest of the system speaks PS/2 set-1
//! scancodes — the framebuffer console, Squeeze's keymap and Peel's routing
//! all assume them. Translating here means USB becomes a second source feeding
//! the same input queue rather than a parallel path everything has to learn.

const std = @import("std");
const event = @import("../input/event.zig");

/// HID usage ID to PS/2 set-1 scancode. Index is the usage, value is the
/// scancode; zero means "no equivalent".
const usage_to_scancode = blk: {
    var t = [_]u8{0} ** 256;

    // Letters: usage 0x04..0x1D is A..Z.
    const letters = [_]u8{
        0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, // a-j
        0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, // k-t
        0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C, // u-z
    };
    for (letters, 0..) |sc, i| t[0x04 + i] = sc;

    // Digits: usage 0x1E..0x27 is 1..9 then 0.
    const digits = [_]u8{ 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
    for (digits, 0..) |sc, i| t[0x1E + i] = sc;

    t[0x28] = 0x1C; // enter
    t[0x29] = 0x01; // escape
    t[0x2A] = 0x0E; // backspace
    t[0x2B] = 0x0F; // tab
    t[0x2C] = 0x39; // space
    t[0x2D] = 0x0C; // minus
    t[0x2E] = 0x0D; // equals
    t[0x2F] = 0x1A; // left bracket
    t[0x30] = 0x1B; // right bracket
    t[0x31] = 0x2B; // backslash
    t[0x33] = 0x27; // semicolon
    t[0x34] = 0x28; // apostrophe
    t[0x35] = 0x29; // grave
    t[0x36] = 0x33; // comma
    t[0x37] = 0x34; // period
    t[0x38] = 0x35; // slash

    break :blk t;
};

const MOD_LSHIFT: u8 = 1 << 1;
const MOD_RSHIFT: u8 = 1 << 5;

const SCANCODE_LSHIFT: u8 = 0x2A;

/// Previous report, so key presses and releases can be derived. HID sends the
/// full set of held keys every time rather than transitions, so working out
/// what changed is the driver's job.
var last_keys: [6]u8 = [_]u8{0} ** 6;
var last_modifiers: u8 = 0;

fn wasHeld(usage: u8) bool {
    for (last_keys) |k| {
        if (k == usage) return true;
    }
    return false;
}

fn isHeld(report: []const u8, usage: u8) bool {
    var i: usize = 2;
    while (i < @min(report.len, 8)) : (i += 1) {
        if (report[i] == usage) return true;
    }
    return false;
}

pub fn handleKeyboard(report: []const u8) void {
    if (report.len < 8) return;

    const modifiers = report[0];

    // Shift is a modifier bit rather than a key in the array, so it has to be
    // turned back into a press and release of its own.
    const shift_now = modifiers & (MOD_LSHIFT | MOD_RSHIFT) != 0;
    const shift_was = last_modifiers & (MOD_LSHIFT | MOD_RSHIFT) != 0;
    if (shift_now != shift_was) {
        event.pushKey(.{ .code = SCANCODE_LSHIFT, .extended = false, .pressed = shift_now });
    }

    // Newly pressed: in this report, not the last.
    var i: usize = 2;
    while (i < 8) : (i += 1) {
        const usage = report[i];
        if (usage == 0 or usage == 1) continue; // 1 is rollover error
        if (wasHeld(usage)) continue;
        const sc = usage_to_scancode[usage];
        if (sc != 0) event.pushKey(.{ .code = sc, .extended = false, .pressed = true });
    }

    // Released: in the last report, not this one.
    for (last_keys) |usage| {
        if (usage == 0) continue;
        if (isHeld(report, usage)) continue;
        const sc = usage_to_scancode[usage];
        if (sc != 0) event.pushKey(.{ .code = sc, .extended = false, .pressed = false });
    }

    @memcpy(last_keys[0..6], report[2..8]);
    last_modifiers = modifiers;
}

pub fn handleMouse(report: []const u8) void {
    if (report.len < 3) return;

    const buttons = report[0];
    const dx: i8 = @bitCast(report[1]);
    const dy: i8 = @bitCast(report[2]);

    event.pushMouse(.{
        .dx = dx,
        // HID reports Y positive downward, which is already what the screen
        // wants, so unlike PS/2 it is not negated here.
        .dy = dy,
        .left = buttons & 1 != 0,
        .right = buttons & 2 != 0,
        .middle = buttons & 4 != 0,
    });
}
