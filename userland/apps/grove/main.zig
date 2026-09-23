//! Grove: a calm launch surface, using the same artwork as the dock.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
// Build complete frames privately. The compositor must never observe our
// wallpaper/blur/card construction in the shared client surface.
var staging: [430 * 382 * 4]u32 = undefined;
var background: [430 * 382 * 4]u32 = undefined;
const targets = [_]ui.Button{
    .{ .id = 1, .rect = .{ .x = 24, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 2, .rect = .{ .x = 156, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 3, .rect = .{ .x = 288, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 4, .rect = .{ .x = 24, .y = 314, .w = 382, .h = 48 } },
    .{ .id = 5, .rect = .{ .x = 24, .y = 156, .w = 118, .h = 28 } },
    .{ .id = 6, .rect = .{ .x = 156, .y = 156, .w = 118, .h = 28 } },
    .{ .id = 7, .rect = .{ .x = 288, .y = 156, .w = 118, .h = 28 } },
};
fn prepare(win: *const libpeel.Window) void {
    var s = ui.surface(win);
    s.pixels = &background;
    // Build the editorial header once. Hover never recomputes a backdrop,
    // blur or full-window frame; each launch control has isolated damage.
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 430, .h = 382 }, 0, 0xFBFCFE, 0xF0F4FA);
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 430, .h = 141 }, 0, 0xFFFFFF, 0xF3F7FC);
    s.rounded(.{ .x = 24, .y = 24, .w = 4, .h = 12 }, 2, 0xF38B42, 255);
    ui.label(&s, "ORANGE OS", 37, 27, 1, 0x778397);
    ui.label(&s, "A fresh start.", 24, 52, 2, 0x253247);
    ui.label(&s, "Your files, favourite tools", 25, 92, 1, 0x778397);
    ui.label(&s, "and a little room to create.", 25, 112, 1, 0x778397);
    s.rounded(.{ .x = 321, .y = 37, .w = 74, .h = 76 }, 23, 0xDEE8F5, 130);
    ui.icon(&s, .welcome, 319, 32, 78);
    s.fill(.{ .x = 24, .y = 140, .w = 382, .h = 1 }, 0xE1E7EF);
    ui.label(&s, "QUICK LAUNCH", 24, 192, 1, 0x778397);
}
fn control(s: *ui.Surface, t: ui.Button, pointer: ui.Pointer) void {
    const hover = pointer.hover == t.id;
    const pressed = pointer.pressed == t.id;
    const border: u32 = if (pressed) 0xAAC8F4 else if (hover) 0xC3D7F5 else 0xE1E7EF;
    const fill: u32 = if (pressed) 0xE7F0FC else if (hover) 0xF6FAFF else 0xFFFFFF;
    if (t.id <= 3) {
        const kinds = [_]ui.Icon{ .files, .terminal, .clock };
        const titles = [_][]const u8{ "Files", "Terminal", "Clock" };
        s.rounded(.{ .x = t.rect.x, .y = t.rect.y + 2, .w = t.rect.w, .h = t.rect.h }, 15, 0x253247, 9);
        s.rounded(t.rect, 15, border, 255);
        s.rounded(.{ .x = t.rect.x + 1, .y = t.rect.y + 1, .w = t.rect.w - 2, .h = t.rect.h - 2 }, 14, fill, 255);
        ui.icon(s, kinds[t.id - 1], t.rect.x + 37, t.rect.y + 10, 44);
        ui.label(s, titles[t.id - 1], t.rect.x + 14, t.rect.y + 68, 1, 0x253247);
        ui.icon(s, .chevron_right, t.rect.right() - 26, t.rect.y + 62, 17);
    } else if (t.id == 4) {
        s.rounded(t.rect, 12, border, 255);
        s.rounded(.{ .x = t.rect.x + 1, .y = t.rect.y + 1, .w = t.rect.w - 2, .h = t.rect.h - 2 }, 11, fill, 255);
        ui.icon(s, .appearance, t.rect.x + 12, t.rect.y + 8, 30);
        ui.label(s, "Make it yours", t.rect.x + 54, t.rect.y + 11, 1, 0x253247);
        ui.label(s, "Wallpaper and appearance", t.rect.x + 54, t.rect.y + 29, 1, 0x778397);
        ui.icon(s, .chevron_right, t.rect.right() - 27, t.rect.y + 15, 18);
    } else {
        const kinds = [_]ui.Icon{ .windows, .trash, .about };
        const names = [_][]const u8{ "Windows", "Trash", "About" };
        s.rounded(t.rect, 8, if (pressed) 0xE0EAF8 else if (hover) 0xEAF1FB else 0xFFFFFF, if (hover or pressed) 255 else 105);
        ui.icon(s, kinds[t.id - 5], t.rect.x + 8, t.rect.y + 4, 20);
        ui.label(s, names[t.id - 5], t.rect.x + 36, t.rect.y + 10, 1, 0x556378);
    }
}
fn paint(win: *const libpeel.Window, pointer: ui.Pointer, previous: ?ui.Pointer) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    if (previous == null) {
        const length: usize = @intCast(win.stride * win.height * win.scale);
        @memcpy(staging[0..length], background[0..length]);
        for (targets) |t| control(&s, t, pointer);
        ui.publishRegion(win, staging[0..length], .{ .x = 0, .y = 0, .w = win.width, .h = win.height });
    } else for (targets) |t| {
        const old = previous.?;
        if ((old.hover == t.id) == (pointer.hover == t.id) and (old.pressed == t.id) == (pointer.pressed == t.id)) continue;
        const r = ui.Rect{ .x = t.rect.x, .y = t.rect.y, .w = t.rect.w, .h = t.rect.h + 2 };
        var y = r.y * win.scale;
        while (y < r.bottom() * win.scale) : (y += 1) {
            const start: usize = @intCast(y * win.stride + r.x * win.scale);
            const n: usize = @intCast(r.w * win.scale);
            @memcpy(staging[start..][0..n], background[start..][0..n]);
        }
        control(&s, t, pointer);
        ui.publishRegion(win, &staging, r);
    }
    if (pulp.desktop_profile) pulp.puts("grove: painted\n");
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("Welcome", 430, 382, 754, 112) catch pulp.exit(1);
    var pointer: ui.Pointer = .{};
    prepare(&win);
    paint(&win, pointer, null);
    var buf: [128]u8 = undefined;
    while (true) {
        const previous = pointer;
        var dirty = false;
        while (true) {
            const m = pulp.portRecvMsg(win.reply, &buf, false) catch break;
            if (m.len == 0) break;
            if (m.opcode == libpeel.proto.Op.close_requested) {
                win.destroy();
                pulp.exit(0);
            }
            if (m.opcode != libpeel.proto.Op.input or m.len < @sizeOf(libpeel.proto.Input)) continue;
            const ev: *align(1) const libpeel.proto.Input = @ptrCast(&buf);
            if (ev.kind != pulp.EV_MOUSE) continue;
            const old = pointer;
            const action = pointer.update(ev.x, ev.y, ev.code, &targets);
            dirty = dirty or pointer.visualChanged(old);
            if (action >= 1 and action <= 3) {
                const index: u32 = ([_]u32{ 4, 1, 2 })[action - 1];
                _ = pulp.portSend(win.server, libpeel.proto.Op.launch_app, @import("std").mem.asBytes(&index)) catch {};
            } else if (action == 4 or action == 5) {
                const panel: u32 = if (action == 4) 6 else 5;
                _ = pulp.portSend(win.server, libpeel.proto.Op.desktop_panel, @import("std").mem.asBytes(&panel)) catch {};
            } else if (action == 6 or action == 7) {
                const index: u32 = if (action == 6) 5 else 3;
                _ = pulp.portSend(win.server, libpeel.proto.Op.launch_app, @import("std").mem.asBytes(&index)) catch {};
            }
        }
        if (dirty and pointer.visualChanged(previous)) paint(&win, pointer, previous);
        pulp.sleepMs(16);
    }
}
