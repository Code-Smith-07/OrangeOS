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
    ui.gradient(&surface, .{ .x = 0, .y = 0, .w = 360, .h = 210 }, 0, 0xF8FAFE, 0xEEF3FA);
    surface.rounded(.{ .x = 20, .y = 20, .w = 320, .h = 172 }, 16, 0x253247, 10);
    surface.rounded(.{ .x = 20, .y = 18, .w = 320, .h = 172 }, 16, 0xE1E7EF, 255);
    surface.rounded(.{ .x = 21, .y = 19, .w = 318, .h = 170 }, 15, 0xFFFFFF, 255);
    surface.rounded(.{ .x = 42, .y = 28, .w = 24, .h = 3 }, 1, 0xF38B42, 255);
    surface.fill(.{ .x = 42, .y = 139, .w = 276, .h = 1 }, 0xE1E7EF);
    ui.icon(&surface, .clock, 282, 34, 30);
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
            // Card and gradient are immutable. Build time text privately and
            // publish only the changed digits, not 75,600 logical pixels.
            @memcpy(staging[0..length], background[0..length]);
            if (seconds) |value| {
                const date = pulp.calendar.fromEpoch(value, pulp.timezone_minutes);
                var buf: [64]u8 = undefined;
                const label = pulp.calendar.dateText(&buf, date);
                typography.drawText(&frame, label, 42, 49, 1, 0x778397);
                const clock = pulp.calendar.clockText(&buf, date);
                typography.drawText(&frame, clock, @divTrunc(win.width - typography.textWidth(clock, 3), 2), 85, 3, 0x253247);
                const offset = pulp.timezone_minutes;
                const tz = std.fmt.bufPrint(&buf, "{d}  /  UTC{s}{d:0>2}:{d:0>2}", .{ date.year, if (offset < 0) "-" else "+", @abs(offset) / 60, @abs(offset) % 60 }) catch "";
                typography.drawText(&frame, tz, 42, 160, 1, 0x778397);
            } else typography.drawText(&frame, "Hardware clock unavailable", 36, 88, 1, 0x556378);
            const dirty = if (painted) ui.gfx.changedPixelBounds(win.pixels[0..length], staging[0..length], win.stride, win.scale) else ui.Rect{ .x = 0, .y = 0, .w = win.width, .h = win.height };
            ui.publishRegion(&win, staging[0..length], dirty);
            painted = true;
        }
        pulp.sleepMs(100);
    }
}
