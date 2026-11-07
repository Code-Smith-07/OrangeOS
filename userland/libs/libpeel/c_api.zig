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
    /// 1 key, 2 mouse, 3 the user asked to close the window, 4 wheel,
    /// 5 resize: draw at x by y, then call orange_peel_ack_resize.
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

/// A resizable window with full-size content (docs/design/014, M2): the
/// program draws its own top bar, `bar_height` tall, under the window
/// buttons, and the buffer holds the largest size the screen allows
/// (`info.stride` is that width, not `info.width`).
export fn orange_peel_open_resizable(title: [*:0]const u8, width: i32, height: i32, min_width: i32, min_height: i32, bar_height: i32, info: *Info) c_int {
    if (window != null) return -1;
    const flags = libpeel.proto.WindowFlags.closable | libpeel.proto.WindowFlags.resizable | libpeel.proto.WindowFlags.full_size_content;
    const w = libpeel.open(.{ .title = std.mem.span(title), .width = width, .height = height, .flags = flags, .min_w = min_width, .min_h = min_height, .bar_height = bar_height }) catch return -1;
    window = w;
    info.* = .{ .width = w.width, .height = w.height, .scale = w.scale, .stride = w.stride, .pixels = w.pixels };
    return 0;
}

/// The buffer now shows a frame of width by height.
export fn orange_peel_ack_resize(width: i32, height: i32) void {
    const w = &(window orelse return);
    const msg = libpeel.proto.Configure{ .window_id = w.id, .width = @intCast(@max(0, width)), .height = @intCast(@max(0, height)) };
    _ = pulp.portSend(w.server, libpeel.proto.Op.resized, std.mem.asBytes(&msg)) catch {};
}

/// The user pressed the program's own top bar: move the window.
export fn orange_peel_move_request() void {
    if (window) |*w| w.requestMove();
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
        if (m.opcode == libpeel.proto.Op.configure and m.len >= @sizeOf(libpeel.proto.Configure)) {
            const c: *align(1) const libpeel.proto.Configure = @ptrCast(&buf);
            if (c.window_id != w.id) continue;
            const cw = std.math.clamp(@as(i32, @intCast(@min(c.width, 4096))), @max(1, w.min_w), @max(1, w.capacity_w));
            const ch = std.math.clamp(@as(i32, @intCast(@min(c.height, 4096))), @max(1, w.min_h), @max(1, w.capacity_h));
            event.* = .{ .kind = 5, .code = 0, .value = 0, .x = cw, .y = ch };
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
