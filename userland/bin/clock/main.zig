//! Live civil clock. Monotonic uptime remains a separate diagnostics API.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const typography = @import("typography");
const ui = @import("ui");
const std = @import("std");
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("clock", 360, 210, 460, 390) catch pulp.exit(1);
    pulp.print("clock: got window {d} ({d}x{d})\n", .{ win.id, win.width, win.height });
    var last: ?u64 = null;
    var painted = false;
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
            painted = true;
            var surface = ui.surface(&win);
            ui.gradient(&surface, .{ .x = 0, .y = 0, .w = 360, .h = 210 }, 0, 0xFAE3E7, 0xDADAF4);
            surface.frost(.{ .x = 20, .y = 20, .w = 320, .h = 170 }, 22, 0xFFFFFF, 130);
            ui.icon(&surface, .clock, 281, 33, 34);
            if (seconds) |value| {
                const date = pulp.calendar.fromEpoch(value, pulp.timezone_minutes);
                var buf: [64]u8 = undefined;
                const label = pulp.calendar.dateText(&buf, date);
                typography.drawText(&win, label, 42, 43, 1, 0x8A738E);
                const clock = pulp.calendar.clockText(&buf, date);
                typography.drawText(&win, clock, @divTrunc(win.width - typography.textWidth(clock, 3), 2), 83, 3, 0x554965);
                const offset = pulp.timezone_minutes;
                const tz = std.fmt.bufPrint(&buf, "{d}  /  UTC{s}{d:0>2}:{d:0>2}", .{ date.year, if (offset < 0) "-" else "+", @abs(offset) / 60, @abs(offset) % 60 }) catch "";
                typography.drawText(&win, tz, 42, 150, 1, 0x786190);
            } else typography.drawText(&win, "Hardware clock unavailable", 36, 88, 1, 0x584176);
            win.commitAll();
        }
        pulp.sleepMs(100);
    }
}
