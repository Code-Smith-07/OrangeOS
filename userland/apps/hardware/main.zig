//! Read-only host hardware view. No raw transport/key access, no pretend toggles.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const model = @import("model.zig");
var staging: [480 * 330 * 4]u32 = undefined;
var json_memory: [32768]u8 = undefined;
fn paint(win: *const libpeel.Window, state: model.Model) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 480, .h = 330 }, 0, 0xFCFDFE, 0xF1F5FA);
    ui.icon(&s, .controls, 23, 23, 34);
    ui.label(&s, "Mac hardware", 73, 28, 2, 0x253247);
    // Never describe an expired or absent companion as connected.
    ui.label(&s, if (state.connection == .fresh) "Connected to your Mac. Read-only, by design." else "Host readback / controls not enabled", 24, 68, 1, 0x778397);
    if (state.connection == .disconnected or state.connection == .invalid) {
        s.rounded(.{ .x = 18, .y = 96, .w = 444, .h = 192 }, 14, 0xE1E7EF, 255);
        s.rounded(.{ .x = 19, .y = 97, .w = 442, .h = 190 }, 13, 0xFFFFFF, 255);
        ui.icon(&s, .controls, 215, 120, 48);
        ui.label(&s, if (state.connection == .invalid) "Host data unavailable / invalid snapshot" else "Companion disconnected or unavailable", 42, 200, 1, 0x253247);
        ui.label(&s, if (state.connection == .invalid) "Waiting for a valid v1 host hardware snapshot." else "Start a bridge-enabled VM session to connect.", 32, 231, 1, 0x778397);
        ui.publishRegion(win, &staging, .{ .x = 0, .y = 0, .w = win.width, .h = win.height });
        return;
    }
    for (state.rows, [_][]const u8{ "Wi-Fi", "Bluetooth", "Brightness" }, 0..) |row, title, i| {
        const y: i32 = 96 + @as(i32, @intCast(i)) * 64;
        s.rounded(.{ .x = 18, .y = y, .w = 444, .h = 56 }, 11, 0xE1E7EF, 255);
        s.rounded(.{ .x = 19, .y = y + 1, .w = 442, .h = 54 }, 10, 0xFFFFFF, 255);
        ui.label(&s, title, 32, y + 13, 1, 0x253247);
        var buf: [80]u8 = undefined;
        const label: []const u8 = switch (row.reading) {
            .on => "On (Mac)",
            .off => "Off (Mac)",
            .percent => |p| std.fmt.bufPrint(&buf, "{d}% (read-only)", .{p}) catch "Unavailable",
            .status => |status| switch (status) {
                .available => "Available / read-only",
                .unknown => "Unknown",
                .unavailable => "Unavailable",
                .unsupported => "Not supported by adapter",
                .ambiguous => "Display selection needed",
                .permission_required => "Host permission needed",
                .denied => "Host permission denied",
                .restricted => "Restricted by host policy",
                .stale => "Stale / awaiting host",
            },
        };
        s.setClip(.{ .x = 190, .y = y + 4, .w = 256, .h = 25 });
        ui.label(&s, label, 190, y + 13, 1, switch (row.reading) {
            .on, .percent => 0x287D67,
            .off => 0x556378,
            .status => 0x778397,
        });
        s.setClip(.{ .x = 32, .y = y + 29, .w = 414, .h = 22 });
        ui.label(&s, row.source.text(), 32, y + 35, 1, 0x8994A5);
        s.resetClip();
    }
    ui.label(&s, "No radio, pairing or brightness changes are made.", 24, 306, 1, 0x778397);
    ui.publishRegion(win, &staging, .{ .x = 0, .y = 0, .w = win.width, .h = win.height });
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("Mac hardware", 480, 330, 390, 185) catch pulp.exit(1);
    var buffer: [4096]u8 = undefined;
    var previous: ?model.Model = null;
    var events: [128]u8 = undefined;
    while (true) {
        while (true) {
            const event = pulp.portRecvMsg(win.reply, &events, false) catch break;
            if (event.len == 0) break;
            if (event.opcode == libpeel.proto.Op.close_requested) {
                win.destroy();
                pulp.puts("hardware: closed\n");
                pulp.exit(0);
            }
        }
        const result = pulp.syscall3(111, 0, @intFromPtr(&buffer), buffer.len);
        const n: usize = if (result > 0) @intCast(result) else 0;
        const state = model.parse(buffer[0..n], &json_memory);
        if (previous == null or !previous.?.eql(state)) {
            paint(&win, state);
            previous = state;
            pulp.print("hardware: view {s}\n", .{if (n == 0) "unavailable" else "snapshot"});
        }
        pulp.sleepMs(250);
    }
}
