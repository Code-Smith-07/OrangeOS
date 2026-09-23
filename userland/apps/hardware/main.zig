//! Native Control Center backed by expiring Mac observations and consented RPC.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const model = @import("model.zig");
const W = 480;
const H = 480;
fn sliderRect(index: usize) ui.Rect {
    return .{ .x = 18, .y = 176 + @as(i32, @intCast(index)) * 118, .w = 444, .h = 106 };
}
fn sliderHit(index: usize) ui.Rect {
    return .{ .x = 66, .y = sliderRect(index).y + 40, .w = 370, .h = 34 };
}
var staging: [W * H * 4]u32 = undefined;
var json_memory: [32768]u8 = undefined;
var previews: [2]?u8 = .{ null, null };
var messages: [2][]const u8 = .{ "", "" };
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
    var text: [64]u8 = undefined;
    for (0..2) |i| {
        const r = sliderRect(i);
        const row = state.rows[2 + i];
        card(&s, r);
        ui.icon(&s, if (i == 0) .sun else .speaker, 32, r.y + 43, 29);
        ui.label(&s, if (i == 0) "Mac display brightness" else "Mac output volume", 32, r.y + 15, 1, 0x17334D);
        if (row.reading == .percent) {
            ui.label(&s, if (row.muted == true) "Muted" else reading(row, &text), 370, r.y + 15, 1, 0x56728D);
            const enabled = row.control and state.connection == .fresh;
            const value = previews[i] orelse row.reading.percent;
            s.rounded(.{ .x = 78, .y = r.y + 54, .w = 342, .h = 7 }, 3, 0xD2E1EC, 255);
            s.rounded(.{ .x = 78, .y = r.y + 54, .w = @divTrunc(342 * @as(i32, value), 100), .h = 7 }, 3, if (enabled) 0x239DEE else 0x97B3CA, 255);
            const thumb = 78 + @divTrunc(342 * @as(i32, value), 100);
            s.circle(thumb, r.y + 58, 11, 0xBED2E2);
            s.circle(thumb, r.y + 57, 9, 0xFFFFFF);
            ui.label(&s, if (previews[i] != null) "Release to apply to this Mac" else if (messages[i].len != 0) messages[i] else if (enabled) (if (i == 0) "Built-in Mac display / 5-100%" else "Controls the Mac's current sound output") else if (i == 0) "Enable brightness in the Mac companion menu" else "Enable sound control in the Mac companion menu", 32, r.y + 84, 1, 0x6D849A);
        } else {
            ui.label(&s, reading(row, &text), 80, r.y + 51, 1, 0x6D849A);
        }
    }
    card(&s, .{ .x = 18, .y = 414, .w = 444, .h = 50 });
    ui.icon(&s, if (state.rows[4].power == true) .battery else .battery_plain, 32, 424, 30);
    ui.label(&s, "Battery", 80, 428, 1, 0x17334D);
    const battery = state.rows[4];
    const value_text = reading(battery, &text);
    var power_text: [96]u8 = undefined;
    const power = if (battery.power == true) " / Power connected" else if (battery.power == false) " / On battery" else "";
    const label = std.fmt.bufPrint(&power_text, "{s}{s}", .{ value_text, power }) catch value_text;
    ui.label(&s, label, 187, 428, 1, 0x56728D);
    ui.publishRegion(win, &staging, region);
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("Control Center", W, H, 390, 145) catch pulp.exit(1);
    var buffer: [4096]u8 = undefined;
    var state: model.Model = .{};
    var events: [128]u8 = undefined;
    var pending: u64 = 0;
    var down = false;
    var captured: ?usize = null;
    var pending_control: usize = 0;
    var last_poll: u64 = 0;
    const full: ui.Rect = .{ .x = 0, .y = 0, .w = W, .h = H };
    paint(&win, state, full);
    while (true) {
        var dirty = [_]bool{ false, false };
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
            if (pressed and !down) {
                captured = null;
                if (pending == 0) for (0..2) |i| {
                    if (state.rows[2 + i].control and sliderHit(i).contains(input.x, input.y)) captured = i;
                };
            }
            if (captured) |i| {
                if (pressed) {
                    const raw = @divTrunc(std.math.clamp(input.x - 78, 0, 342) * 100, 342);
                    const percent: u8 = @intCast(@max(if (i == 0) @as(i32, 5) else 0, raw));
                    if (previews[i] == null or previews[i].? != percent) {
                        previews[i] = percent;
                        dirty[i] = true;
                    }
                } else if (down) {
                    if (previews[i]) |percent| {
                        if (sliderHit(i).contains(input.x, input.y) and state.rows[2 + i].control) {
                            const id = pulp.syscall3(112, if (i == 0) 5 else 0, percent, state.rows[2 + i].device);
                            if (id > 0) {
                                pending = @intCast(id);
                                pending_control = i;
                                messages[i] = "Applying to your Mac...";
                            } else {
                                messages[i] = "Request unavailable. Please try again.";
                            }
                        }
                    }
                    captured = null;
                    previews[i] = null;
                    dirty[i] = true;
                }
            }
            down = pressed;
        }
        if (pending != 0) {
            const result = pulp.syscall3(112, 1, pending, 0);
            if (result != -11) {
                messages[pending_control] = switch (result) {
                    0 => if (pending_control == 0) "Mac brightness updated" else "Mac volume updated",
                    -13 => "Permission revoked on Mac",
                    -95 => "This device does not support control",
                    -116 => "Mac device changed. Try again.",
                    -110, -107 => "Mac connection lost. Try again.",
                    else => "Could not update this Mac setting",
                };
                pending = 0;
                dirty[pending_control] = true;
                pulp.print("hardware: {s} result {d}\n", .{ if (pending_control == 0) "brightness" else "sound", result });
            }
        }
        const now = pulp.uptimeMs();
        if (now -| last_poll >= 250) {
            last_poll = now;
            const result = pulp.syscall3(111, 0, @intFromPtr(&buffer), buffer.len);
            const n: usize = if (result > 0) @intCast(result) else 0;
            const next = model.parse(buffer[0..n], &json_memory);
            if (!state.eql(next)) {
                for (0..2) |i| {
                    if (!next.rows[2 + i].control or next.rows[2 + i].device != state.rows[2 + i].device) {
                        if (captured == i) captured = null;
                        previews[i] = null;
                    }
                }
                state = next;
                paint(&win, state, full);
                dirty = .{ false, false };
                pulp.print("hardware: view {s}\n", .{if (n == 0) "unavailable" else "snapshot"});
            }
        }
        for (dirty, 0..) |changed, i| if (changed) {
            paint(&win, state, sliderRect(i));
        };
        pulp.sleepMs(20);
    }
}
