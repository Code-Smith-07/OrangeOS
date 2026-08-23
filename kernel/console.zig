//! Unified kernel console — broadcasts to every output that is up.
//!
//! Serial comes online first and always receives output. The framebuffer joins
//! once a video mode is available. Writing before either exists is a no-op
//! rather than a fault.

const serial = @import("drivers/char/serial.zig");
const fbcon = @import("drivers/video/fbcon.zig");
const fmt = @import("lib/fmt.zig");

pub fn write(s: []const u8) void {
    if (serial.isInitialized()) serial.write(s);
    if (fbcon.isReady()) fbcon.write(s);
}

/// Formatted output. The 512-byte line buffer is a deliberate cap: kernel log
/// lines that need more than that are a design smell.
pub fn print(comptime format: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    write(fmt.bufPrint(&buf, format, args));
}

// ── Log levels ───────────────────────────────────────────────────────────────
// Serial gets plain text; the framebuffer gets color, so boot output is
// scannable at a glance.

fn tagged(tag: []const u8, color: u32, comptime format: []const u8, args: anytype) void {
    if (serial.isInitialized()) {
        serial.write(tag);
        var buf: [512]u8 = undefined;
        serial.write(fmt.bufPrint(&buf, format, args));
        serial.write("\n");
    }
    if (fbcon.isReady()) {
        fbcon.setColor(color);
        fbcon.write(tag);
        fbcon.resetColor();
        var buf: [512]u8 = undefined;
        fbcon.write(fmt.bufPrint(&buf, format, args));
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
