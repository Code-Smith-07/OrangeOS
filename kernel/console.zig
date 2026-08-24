//! Unified kernel console — broadcasts to every output that is up.
//!
//! Serial comes online first and always receives output. The framebuffer joins
//! once a video mode is available. Writing before either exists is a no-op
//! rather than a fault.

const serial = @import("drivers/char/serial.zig");
const fbcon = @import("drivers/video/fbcon.zig");
const fmt = @import("lib/fmt.zig");
const spinlock = @import("sync/spinlock.zig");

/// Console output must be atomic per line once preemption exists. The
/// framebuffer console keeps cursor state and scrolls by moving scanlines;
/// two threads interleaving inside that produce visibly corrupted output.
/// Interrupts are disabled while held, because the timer handler also prints.
var lock: spinlock.SpinLock = .{};

pub fn write(s: []const u8) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    writeLocked(s);
}

fn writeLocked(s: []const u8) void {
    if (serial.isInitialized()) serial.write(s);
    if (fbcon.isReady()) fbcon.write(s);
}

/// Formatted output. The 512-byte line buffer is a deliberate cap: kernel log
/// lines that need more than that are a design smell.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = fmt.bufPrint(&buf, format, args);
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    writeLocked(text);
}

// ── Log levels ───────────────────────────────────────────────────────────────
// Serial gets plain text; the framebuffer gets color, so boot output is
// scannable at a glance.

fn tagged(tag: []const u8, color: u32, comptime format: []const u8, args: anytype) void {
    // Format before taking the lock: formatting is pure and can be preempted
    // safely, and holding the lock across it would lengthen every critical
    // section for no reason.
    var buf: [512]u8 = undefined;
    const text = fmt.bufPrint(&buf, format, args);

    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    if (serial.isInitialized()) {
        serial.write(tag);
        serial.write(text);
        serial.write("\n");
    }
    if (fbcon.isReady()) {
        fbcon.setColor(color);
        fbcon.write(tag);
        fbcon.resetColor();
        fbcon.write(text);
        fbcon.write("\n");
    }
}

pub fn ok(comptime format: []const u8, args: anytype) void {
    tagged("[ ok ] ", fbcon.theme.accent, format, args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    tagged("[info] ", fbcon.theme.dim, format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    tagged("[warn] ", fbcon.theme.accent, format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    tagged("[FAIL] ", fbcon.theme.accent, format, args);
}
