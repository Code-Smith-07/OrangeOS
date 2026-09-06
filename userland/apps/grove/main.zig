//! Grove: a welcoming launch surface, using the same artwork as the dock.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
// Build complete frames privately. The compositor must never observe our
// wallpaper/blur/card construction in the shared client surface.
var staging: [430 * 382 * 4]u32 = undefined;
const targets = [_]ui.Button{
    .{ .id = 1, .rect = .{ .x = 24, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 2, .rect = .{ .x = 156, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 3, .rect = .{ .x = 288, .y = 206, .w = 118, .h = 92 } },
    .{ .id = 4, .rect = .{ .x = 24, .y = 314, .w = 382, .h = 48 } },
};
fn paint(win: *const libpeel.Window, pointer: ui.Pointer) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    // The full-resolution aurora is reconstructed before every glass
    // pass, never blurred repeatedly over an old card.
    var y: i32 = 0;
    while (y < s.height * s.scale) : (y += 1) {
        var x: i32 = 0;
        while (x < s.width * s.scale) : (x += 1) {
            const nx = @divTrunc(x * 430, s.width * s.scale);
            const ny = @divTrunc(y * 382, s.height * s.scale);
            const peach = @max(0, 255 - @divTrunc((nx - 400) * (nx - 400) + (ny - 70) * (ny - 70), 240));
            const violet = @max(0, 255 - @divTrunc((nx - 25) * (nx - 25) + (ny - 310) * (ny - 310), 390));
            var c = ui.gfx.lerp(0xF2EEFD, 0xFDC2B1, @intCast(peach));
            c = ui.gfx.lerp(c, 0xCBC3F2, @intCast(violet));
            s.putPhysical(x, y, c);
        }
    }
    s.rounded(.{ .x = 302, .y = 45, .w = 99, .h = 103 }, 29, 0x9569AE, 22);
    s.frost(.{ .x = 298, .y = 39, .w = 99, .h = 103 }, 28, 0xFFFFFF, 60);
    ui.icon(&s, .welcome, 307, 48, 82);
    ui.label(&s, "O R A N G E   O S", 24, 23, 1, 0x7B698D);
    ui.label(&s, "Make yourself", 24, 61, 2, 0x37334F);
    ui.label(&s, "at home.", 24, 94, 2, 0x37334F);
    ui.label(&s, "A little colour. A world of possibility.", 24, 153, 1, 0x726984);
    ui.label(&s, "YOUR EVERYDAY ESSENTIALS", 24, 191, 1, 0x7E7593);
    const kinds = [_]ui.Icon{ .files, .terminal, .clock };
    const titles = [_][]const u8{ "Files", "Terminal", "Clock" };
    for (targets[0..3], 0..) |t, i| {
        const hover = pointer.hover == t.id;
        s.rounded(.{ .x = t.rect.x, .y = t.rect.y + 4, .w = t.rect.w, .h = t.rect.h }, 18, 0x887EA8, 24);
        s.frost(t.rect, 18, 0xFFFFFF, if (pointer.pressed == t.id) 90 else if (hover) 200 else 145);
        s.rounded(.{ .x = t.rect.x + 18, .y = t.rect.y, .w = t.rect.w - 36, .h = 1 }, 0, 0xFFFFFF, 210);
        ui.icon(&s, kinds[i], t.rect.x + 35, t.rect.y + 7, 48);
        ui.label(&s, titles[i], t.rect.x + 16, t.rect.y + 65, 1, 0x333852);
        ui.icon(&s, .chevron_right, t.rect.right() - 28, t.rect.y + 59, 20);
    }
    const r = targets[3].rect;
    s.frost(r, 16, 0xFFFFFF, if (pointer.hover == 4) 170 else 100);
    ui.icon(&s, .appearance, r.x + 9, r.y + 6, 34);
    ui.label(&s, "Your desktop, your way", r.x + 53, r.y + 12, 1, 0x55477C);
    ui.label(&s, "Choose a wallpaper", r.x + 53, r.y + 29, 1, 0x88809D);
    ui.icon(&s, .chevron_right, r.right() - 29, r.y + 14, 20);
    @memcpy(win.pixels[0..@intCast(win.stride * win.height * win.scale)], staging[0..@intCast(win.stride * win.height * win.scale)]);
    win.commitAll();
    if (pulp.desktop_profile) pulp.puts("grove: painted\n");
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("Welcome", 430, 382, 754, 112) catch pulp.exit(1);
    var pointer: ui.Pointer = .{};
    paint(&win, pointer);
    var buf: [128]u8 = undefined;
    while (true) {
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
            } else if (action == 4) {
                const panel: u32 = 6;
                _ = pulp.portSend(win.server, libpeel.proto.Op.desktop_panel, @import("std").mem.asBytes(&panel)) catch {};
            }
        }
        if (dirty) paint(&win, pointer);
        pulp.sleepMs(16);
    }
}
