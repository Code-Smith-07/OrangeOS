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

// ── Boot log ────────────────────────────────────────────────────────────────
//
// Everything written to the console is also kept in a ring in memory. When
// something fails late - after a compositor has taken the screen, or on a
// machine with no serial port - the panic handler replays this so the context
// leading up to the failure is visible rather than lost.
//
// A fixed array, never allocated: it has to work before the heap exists and
// still work when the heap is what broke.

const LOG_CAPACITY: usize = 16 * 1024;
var log_buf: [LOG_CAPACITY]u8 = undefined;
var log_head: usize = 0;
var log_wrapped: bool = false;

fn logWrite(s: []const u8) void {
    for (s) |c| {
        log_buf[log_head] = c;
        log_head += 1;
        if (log_head == LOG_CAPACITY) {
            log_head = 0;
            log_wrapped = true;
        }
    }
}

/// Replay the retained log. Called from the panic path, so it deliberately
/// takes no locks: whatever we were doing when things broke may have been
/// holding one.
pub fn replayLog() void {
    if (log_wrapped) {
        writeLocked(log_buf[log_head..]);
    }
    writeLocked(log_buf[0..log_head]);
}

pub fn write(s: []const u8) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    logWrite(s);
    writeLocked(s);
}

fn writeLocked(s: []const u8) void {
    if (serial.isInitialized()) serial.write(s);
    if (fbcon.isReady()) fbcon.write(s);
}

/// Write without recording into the log, so replaying it does not append to
/// itself.
fn writeRaw(s: []const u8) void {
    writeLocked(s);
}

/// Write straight to the outputs, bypassing the lock and the log. Panic only.
pub fn emergencyWrite(s: []const u8) void {
    writeRaw(s);
}

/// Formatted output. The 512-byte line buffer is a deliberate cap: kernel log
/// lines that need more than that are a design smell.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = fmt.bufPrint(&buf, format, args);
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    logWrite(text);
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

    logWrite(tag);
    logWrite(text);
    logWrite("\n");

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
