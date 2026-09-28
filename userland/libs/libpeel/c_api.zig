//! libpeel for C programs linked with musl: one window per process.
//!
//! The WPE WebKit browser (userland/bin/orange-browser) is C over GLib, and
//! Peel's client side is Zig. These calls are the whole bridge: open a
//! window and get its pixels, say which rectangle changed, wait for the next
//! input event, close. They use OrangeOS's native calls (pulp), which work
//! the same inside a musl program.
//!
//! next_event() may block, so a program calls it from its own thread while
//! another thread draws and commits; the two use different ports.

const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");

pub const Info = extern struct {
    width: i32,
    height: i32,
    /// Buffer pixels per logical pixel (1, or 2 on a Retina display).
    scale: i32,
    /// In pixels, of the physical buffer.
    stride: i32,
    /// 0x00RRGGBB, `stride * height * scale` of them.
    pixels: [*]u32,
};

pub const Event = extern struct {
    /// 1 key, 2 mouse, 3 the user asked to close the window, 4 wheel.
    kind: u32,
    /// key: set-1 scancode. mouse: buttons held (1 left, 2 right, 4 middle).
    /// wheel: steps as a signed byte, positive towards the user.
    code: u32,
    /// key: bit 0 pressed, bit 1 extended (E0) scancode.
    value: u32,
    /// mouse: logical window coordinates.
    x: i32,
    y: i32,
};

var window: ?libpeel.Window = null;

export fn orange_peel_open(title: [*:0]const u8, width: i32, height: i32, info: *Info) c_int {
    if (window != null) return -1;
    const w = libpeel.createWindow(std.mem.span(title), width, height, -1, -1) catch return -1;
    window = w;
    info.* = .{ .width = w.width, .height = w.height, .scale = w.scale, .stride = w.stride, .pixels = w.pixels };
    return 0;
}

export fn orange_peel_commit(x: i32, y: i32, width: i32, height: i32) void {
    if (window) |*w| w.commit(x, y, width, height);
}

/// 1 when `event` was filled, 0 when nothing was waiting (non-blocking),
/// -1 when the connection is gone.
export fn orange_peel_next_event(event: *Event, blocking: c_int) c_int {
    const w = &(window orelse return -1);
    var buf: [64]u8 = undefined;
    while (true) {
        const m = pulp.portRecvMsg(w.reply, &buf, blocking != 0) catch |e| return switch (e) {
            error.WouldBlock => 0,
            else => -1,
        };
        if (m.opcode == libpeel.proto.Op.close_requested) {
            event.* = .{ .kind = 3, .code = 0, .value = 0, .x = 0, .y = 0 };
            return 1;
        }
        if (m.opcode != libpeel.proto.Op.input or m.len < @sizeOf(libpeel.proto.Input)) continue;
        const input: *align(1) const libpeel.proto.Input = @ptrCast(&buf);
        // Peel's wheel kind (3) is renumbered past close (3) for C.
        const kind: u32 = if (input.kind == pulp.EV_WHEEL) 4 else input.kind;
        event.* = .{ .kind = kind, .code = input.code, .value = input.value, .x = input.x, .y = input.y };
        return 1;
    }
}

export fn orange_peel_close() void {
    if (window) |*w| w.destroy();
    window = null;
}
