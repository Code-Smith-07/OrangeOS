//! Native Control Center backed by expiring Mac observations and consented RPC.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const model = @import("model.zig");
const W = 360;
const H = 424;
const SLIDER_X = 32;
const SLIDER_W = 296;
var palette: u32 = 0;
const Colors = struct { canvas: u32, tile: u32, ink: u32, muted: u32, track: u32 };
fn colors() Colors {
    return switch (palette) {
        2 => .{ .canvas = 0x20242D, .tile = 0x30343E, .ink = 0xF5F6FA, .muted = 0xB2B8C4, .track = 0x535864 },
        1 => .{ .canvas = 0xF4E8E0, .tile = 0xFFF8F1, .ink = 0x392E33, .muted = 0x7C6C70, .track = 0xDDCEC7 },
        else => .{ .canvas = 0xE0EAF3, .tile = 0xF5F9FD, .ink = 0x24313D, .muted = 0x667889, .track = 0xCEDCE8 },
    };
}
fn sliderRect(index: usize) ui.Rect {
    return .{ .x = 12, .y = 154 + @as(i32, @intCast(index)) * 100, .w = 336, .h = 90 };
}
fn sliderHit(index: usize) ui.Rect {
    return .{ .x = SLIDER_X - 8, .y = sliderRect(index).y + 34, .w = SLIDER_W + 16, .h = 30 };
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
    s.rounded(.{ .x = rect.x, .y = rect.y + 2, .w = rect.w, .h = rect.h }, 12, 0x000000, 12);
    s.rounded(rect, 12, colors().tile, 255);
}
fn paint(win: *const libpeel.Window, state: model.Model, region: ui.Rect) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    s.setClip(region);
    const c = colors();
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, c.canvas);
    card(&s, .{ .x = 12, .y = 12, .w = 204, .h = 130 });
    for ([_][]const u8{ "Wi-Fi", "Bluetooth" }, [_]ui.Icon{ .menu_wifi, .menu_bluetooth }, 0..) |title, icon, i| {
        const y: i32 = 25 + @as(i32, @intCast(i)) * 56;
        s.circle(42, y + 16, 17, if (state.rows[i].reading == .on) 0x0787F9 else c.track);
        ui.iconTint(&s, icon, 32, y + 6, 20, 0xFFFFFF);
        ui.label(&s, title, 70, y + 2, 1, c.ink);
        var buf: [48]u8 = undefined;
        s.setClip(ui.Rect.intersect(region, .{ .x = 70, .y = y + 20, .w = 136, .h = 18 }));
        ui.label(&s, reading(state.rows[i], &buf), 70, y + 22, 1, c.muted);
        s.setClip(region);
    }
    card(&s, .{ .x = 226, .y = 12, .w = 122, .h = 130 });
    ui.iconTint(&s, if (state.rows[4].power == true) .menu_battery else .menu_battery_plain, 242, 27, 32, c.ink);
    var battery_buf: [48]u8 = undefined;
    ui.label(&s, "Battery", 242, 72, 1, c.ink);
    s.setClip(ui.Rect.intersect(region, .{ .x = 240, .y = 93, .w = 102, .h = 18 }));
    ui.label(&s, reading(state.rows[4], &battery_buf), 242, 95, 1, c.muted);
    s.setClip(region);
    ui.label(&s, if (state.rows[4].power == true) "Power connected" else if (state.rows[4].power == false) "On battery" else "Mac power", 236, 120, 1, c.muted);
    var text: [64]u8 = undefined;
    for (0..2) |i| {
        const r = sliderRect(i);
        const row = state.rows[2 + i];
        card(&s, r);
        ui.label(&s, if (i == 0) "Display" else "Sound", 26, r.y + 14, 1, c.ink);
        if (row.reading == .percent) {
            ui.label(&s, if (row.muted == true) "Muted" else reading(row, &text), 290, r.y + 14, 1, c.muted);
            const enabled = row.control and state.connection == .fresh;
            const value = previews[i] orelse row.reading.percent;
            s.rounded(.{ .x = 24, .y = r.y + 36, .w = 312, .h = 26 }, 13, c.track, 255);
            const thumb = SLIDER_X + @divTrunc(SLIDER_W * @as(i32, value), 100);
            s.rounded(.{ .x = 24, .y = r.y + 36, .w = thumb - 12, .h = 26 }, 13, if (enabled) 0xF7F9FC else 0x98A4B2, 255);
            s.circle(thumb, r.y + 49, 12, if (enabled) 0xFFFFFF else 0xC4CDD7);
            ui.iconTint(&s, if (i == 0) .sun else .menu_speaker, 31, r.y + 41, 16, 0x647183);
            s.setClip(ui.Rect.intersect(region, .{ .x = 26, .y = r.y + 69, .w = 308, .h = 18 }));
            ui.label(&s, if (previews[i] != null) "Release to apply" else if (messages[i].len != 0) messages[i] else if (enabled) (if (i == 0) "Built-in display / minimum 5%" else "Mac sound output") else "Allow control in Mac companion menu", 26, r.y + 71, 1, c.muted);
            s.setClip(region);
        } else {
            ui.label(&s, reading(row, &text), 26, r.y + 47, 1, c.muted);
        }
    }
    ui.label(&s, switch (state.connection) {
        .fresh => "Connected to your Mac",
        .stale => "Waiting for your Mac",
        .disconnected => "Mac companion disconnected",
        .invalid => "Mac data unavailable",
        .unavailable => "Connecting to your Mac",
    }, 24, 363, 1, c.ink);
    ui.label(&s, "Wi-Fi and Bluetooth: status only", 24, 389, 1, c.muted);
    ui.publishRegion(win, &staging, region);
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindowWithFlags("Control Center", W, H, 0, 0, libpeel.proto.WindowFlags.panel) catch pulp.exit(1);
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
            if (event.opcode == libpeel.proto.Op.appearance and event.len == 4) {
                palette = @as(*align(1) const u32, @ptrCast(&events)).*;
                paint(&win, state, full);
                continue;
            }
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
                    const raw = @divTrunc(std.math.clamp(input.x - SLIDER_X, 0, SLIDER_W) * 100, SLIDER_W);
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
