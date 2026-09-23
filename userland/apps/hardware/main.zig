//! Native Control Center backed by expiring Mac observations and consented RPC.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const model = @import("model.zig");
const W = 480;
const H = 452;
const sound_rect: ui.Rect = .{ .x = 18, .y = 264, .w = 444, .h = 106 };
const slider_hit: ui.Rect = .{ .x = 66, .y = 304, .w = 370, .h = 34 };
var staging: [W * H * 4]u32 = undefined;
var json_memory: [32768]u8 = undefined;
var preview: ?u8 = null;
var message: []const u8 = "";
fn reading(row: model.Row, buf: []u8) []const u8 {
    return switch (row.reading) {
        .on => "On",
        .off => "Off",
        .percent => |p| std.fmt.bufPrint(buf, "{d}%", .{p}) catch "Unknown",
        .status => |status| switch (status) {
            .available => "Available",
            .unknown => "Unknown",
            .unavailable => "Unavailable",
            .unsupported => "Not supported on this Mac",
            .ambiguous => "Choose a device on Mac",
            .permission_required => "Mac permission needed",
            .denied => "Permission denied",
            .restricted => "Restricted",
            .stale => "Reconnecting",
        },
    };
}
fn card(s: *ui.Surface, rect: ui.Rect) void {
    s.rounded(rect, 16, 0xCEE2F2, 255);
    s.rounded(.{ .x = rect.x + 1, .y = rect.y + 1, .w = rect.w - 2, .h = rect.h - 2 }, 15, 0xFFFFFF, 216);
}
fn paint(win: *const libpeel.Window, state: model.Model, region: ui.Rect) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    s.setClip(region);
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = W, .h = H }, 0, 0xECF8FF, 0xD8EAF8);
    ui.label(&s, "Control Center", 24, 21, 2, 0x17334D);
    ui.label(&s, switch (state.connection) {
        .fresh => "Connected to your Mac",
        .stale => "Waiting for your Mac",
        .disconnected => "Mac companion disconnected",
        .invalid => "Mac data unavailable",
        .unavailable => "Connecting to your Mac",
    }, 24, 57, 1, 0x657E96);
    for ([_][]const u8{ "Wi-Fi", "Bluetooth" }, [_]ui.Icon{ .wifi, .bluetooth }, 0..) |title, icon, i| {
        const x: i32 = 18 + @as(i32, @intCast(i)) * 228;
        card(&s, .{ .x = x, .y = 84, .w = 216, .h = 78 });
        s.circle(x + 34, 120, 21, if (state.rows[i].reading == .on) 0x168CEB else 0x879FB6);
        ui.icon(&s, icon, x + 19, 105, 30);
        ui.label(&s, title, x + 65, 101, 1, 0x17334D);
        var buf: [48]u8 = undefined;
        s.setClip(ui.Rect.intersect(region, .{ .x = x + 65, .y = 119, .w = 143, .h = 18 }));
        ui.label(&s, reading(state.rows[i], &buf), x + 65, 123, 1, 0x56728D);
        s.setClip(region);
        ui.label(&s, "Mac radio status", x + 65, 142, 1, 0x7C92A7);
    }
    card(&s, .{ .x = 18, .y = 176, .w = 444, .h = 74 });
    ui.icon(&s, .sun, 34, 195, 30);
    ui.label(&s, "Display brightness", 80, 190, 1, 0x17334D);
    var text: [64]u8 = undefined;
    ui.label(&s, reading(state.rows[2], &text), 80, 218, 1, 0x6D849A);
    card(&s, sound_rect);
    ui.icon(&s, .speaker, 32, 307, 29);
    ui.label(&s, "Mac output volume", 32, 279, 1, 0x17334D);
    const audio = state.rows[3];
    ui.label(&s, if (audio.muted == true) "Muted" else reading(audio, &text), 370, 279, 1, 0x56728D);
    const enabled = audio.control and state.connection == .fresh;
    const value: u8 = preview orelse if (audio.reading == .percent) audio.reading.percent else 0;
    s.rounded(.{ .x = 78, .y = 318, .w = 342, .h = 7 }, 3, 0xD2E1EC, 255);
    if (audio.reading == .percent) {
        s.rounded(.{ .x = 78, .y = 318, .w = @divTrunc(342 * @as(i32, value), 100), .h = 7 }, 3, if (enabled) 0x239DEE else 0x97B3CA, 255);
        const thumb = 78 + @divTrunc(342 * @as(i32, value), 100);
        s.circle(thumb, 322, 11, 0xBED2E2);
        s.circle(thumb, 321, 9, 0xFFFFFF);
    }
    ui.label(&s, if (preview != null) "Release to apply to this Mac" else if (message.len != 0) message else if (enabled) "Controls the Mac's current sound output" else if (audio.reading == .percent) "Enable sound control in the Mac companion menu" else "No controllable sound output available", 32, 348, 1, 0x6D849A);
    card(&s, .{ .x = 18, .y = 384, .w = 444, .h = 50 });
    ui.icon(&s, .battery, 32, 394, 30);
    ui.label(&s, "Battery", 80, 398, 1, 0x17334D);
    const battery = state.rows[4];
    const value_text = reading(battery, &text);
    var power_text: [96]u8 = undefined;
    const power = if (battery.power == true) " / Power connected" else if (battery.power == false) " / On battery" else "";
    const label = std.fmt.bufPrint(&power_text, "{s}{s}", .{ value_text, power }) catch value_text;
    ui.label(&s, label, 187, 398, 1, 0x56728D);
    ui.publishRegion(win, &staging, region);
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("Control Center", W, H, 390, 145) catch pulp.exit(1);
    var buffer: [4096]u8 = undefined;
    var state: model.Model = .{};
    var events: [128]u8 = undefined;
    var pending: u64 = 0;
    var down = false;
    var captured = false;
    var last_poll: u64 = 0;
    const full: ui.Rect = .{ .x = 0, .y = 0, .w = W, .h = H };
    paint(&win, state, full);
    while (true) {
        var dirty_sound = false;
        while (true) {
            const event = pulp.portRecvMsg(win.reply, &events, false) catch break;
            if (event.len == 0) break;
            if (event.opcode == libpeel.proto.Op.close_requested) {
                win.destroy();
                pulp.puts("hardware: closed\n");
                pulp.exit(0);
            }
            if (event.opcode != libpeel.proto.Op.input or event.len < @sizeOf(libpeel.proto.Input)) continue;
            const input: *align(1) const libpeel.proto.Input = @ptrCast(&events);
            if (input.kind != pulp.EV_MOUSE) continue;
            const pressed = input.code & 1 != 0;
            if (pressed and !down) captured = pending == 0 and state.rows[3].control and slider_hit.contains(input.x, input.y);
            if (captured and pressed) {
                const percent: u8 = @intCast(@divTrunc(std.math.clamp(input.x - 78, 0, 342) * 100, 342));
                if (preview == null or preview.? != percent) {
                    preview = percent;
                    dirty_sound = true;
                }
            }
            if (!pressed and down and captured) {
                if (preview) |percent| {
                    if (slider_hit.contains(input.x, input.y) and state.rows[3].control) {
                        const id = pulp.syscall3(112, 0, percent, state.rows[3].device);
                        if (id > 0) {
                            pending = @intCast(id);
                            message = "Applying to Mac sound output...";
                        } else {
                            message = "Request unavailable. Please try again.";
                        }
                    }
                }
                captured = false;
                preview = null;
                dirty_sound = true;
            }
            down = pressed;
        }
        if (pending != 0) {
            const result = pulp.syscall3(112, 1, pending, 0);
            if (result != -11) {
                message = switch (result) {
                    0 => "Mac volume updated",
                    -13 => "Sound permission revoked on Mac",
                    -95 => "Output does not support volume control",
                    -116 => "Sound output changed. Try again.",
                    -110, -107 => "Mac connection lost. Try again.",
                    else => "Could not update Mac volume",
                };
                pending = 0;
                dirty_sound = true;
                pulp.print("hardware: sound result {d}\n", .{result});
            }
        }
        const now = pulp.uptimeMs();
        if (now -| last_poll >= 250) {
            last_poll = now;
            const result = pulp.syscall3(111, 0, @intFromPtr(&buffer), buffer.len);
            const n: usize = if (result > 0) @intCast(result) else 0;
            const next = model.parse(buffer[0..n], &json_memory);
            if (!state.eql(next)) {
                if (!next.rows[3].control or next.rows[3].device != state.rows[3].device) {
                    captured = false;
                    preview = null;
                }
                state = next;
                paint(&win, state, full);
                dirty_sound = false;
                pulp.print("hardware: view {s}\n", .{if (n == 0) "unavailable" else "snapshot"});
            }
        }
        if (dirty_sound) paint(&win, state, sound_rect);
        pulp.sleepMs(20);
    }
}
