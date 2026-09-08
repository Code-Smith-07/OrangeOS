//! Live civil clock. Monotonic uptime remains a separate diagnostics API.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const typography = @import("typography");
const ui = @import("ui");
const std = @import("std");
var background: [360 * 210 * 4]u32 = undefined;
var staging: [360 * 210 * 4]u32 = undefined;
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("clock", 360, 210, 460, 390) catch pulp.exit(1);
    pulp.print("clock: got window {d} ({d}x{d})\n", .{ win.id, win.width, win.height });
    var last: ?u64 = null;
    var painted = false;
    var frame = win;
    frame.pixels = &background;
    var surface = ui.surface(&frame);
    ui.gradient(&surface, .{ .x = 0, .y = 0, .w = 360, .h = 210 }, 0, 0xFAE3E7, 0xDADAF4);
    surface.frost(.{ .x = 20, .y = 20, .w = 320, .h = 170 }, 22, 0xFFFFFF, 130);
    ui.icon(&surface, .clock, 281, 33, 34);
    frame.pixels = &staging;
    const length: usize = @intCast(win.stride * win.height * win.scale);
    var msg: [64]u8 = undefined;
    while (true) {
        while (true) {
            const event = pulp.portRecvMsg(win.reply, &msg, false) catch break;
            if (event.len == 0) break;
            if (event.opcode == libpeel.proto.Op.close_requested) {
                win.destroy();
                pulp.puts("clock: closed\n");
                pulp.exit(0);
            }
        }
        const seconds = pulp.wallTime();
        if (!painted or seconds != last) {
            last = seconds;
            // Frost/gradient are immutable. Build time text privately and
            // publish only the changed digits, not 75,600 logical pixels.
            @memcpy(staging[0..length], background[0..length]);
            if (seconds) |value| {
                const date = pulp.calendar.fromEpoch(value, pulp.timezone_minutes);
                var buf: [64]u8 = undefined;
                const label = pulp.calendar.dateText(&buf, date);
                typography.drawText(&frame, label, 42, 43, 1, 0x8A738E);
                const clock = pulp.calendar.clockText(&buf, date);
                typography.drawText(&frame, clock, @divTrunc(win.width - typography.textWidth(clock, 3), 2), 83, 3, 0x554965);
                const offset = pulp.timezone_minutes;
                const tz = std.fmt.bufPrint(&buf, "{d}  /  UTC{s}{d:0>2}:{d:0>2}", .{ date.year, if (offset < 0) "-" else "+", @abs(offset) / 60, @abs(offset) % 60 }) catch "";
                typography.drawText(&frame, tz, 42, 150, 1, 0x786190);
            } else typography.drawText(&frame, "Hardware clock unavailable", 36, 88, 1, 0x584176);
            const dirty = if (painted) ui.gfx.changedPixelBounds(win.pixels[0..length], staging[0..length], win.stride, win.scale) else ui.Rect{ .x = 0, .y = 0, .w = win.width, .h = win.height };
            var y = dirty.y * win.scale;
            while (y < dirty.bottom() * win.scale) : (y += 1) {
                const start: usize = @intCast(y * win.stride + dirty.x * win.scale);
                const n: usize = @intCast(dirty.w * win.scale);
                @memcpy(win.pixels[start..][0..n], staging[start..][0..n]);
            }
            if (!dirty.isEmpty()) win.commit(dirty.x, dirty.y, dirty.w, dirty.h);
            painted = true;
        }
        pulp.sleepMs(100);
    }
}
