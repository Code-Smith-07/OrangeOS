//! About Orange OS: a quiet system identity and version card.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
var background: [420 * 338 * 4]u32 = undefined;
var staging: [420 * 338 * 4]u32 = undefined;
const done = [_]ui.Button{.{ .id = 1, .rect = .{ .x = 280, .y = 282, .w = 112, .h = 36 } }};
fn prepare(win: *const libpeel.Window) void {
    var s = ui.surface(win);
    s.pixels = &background;
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 420, .h = 338 }, 0, 0xFFFFFF, 0xF4F7FC);
    ui.icon(&s, .welcome, 28, 24, 72);
    ui.label(&s, "Orange OS", 119, 37, 2, 0x253247);
    ui.label(&s, "Daybreak desktop", 120, 76, 1, 0x778397);
    s.fill(.{ .x = 24, .y = 116, .w = 372, .h = 1 }, 0xE1E7EF);
    s.rounded(.{ .x = 24, .y = 135, .w = 372, .h = 122 }, 12, 0xE1E7EF, 255);
    s.rounded(.{ .x = 25, .y = 136, .w = 370, .h = 120 }, 11, 0xFFFFFF, 255);
    const keys = [_][]const u8{ "Version", "Architecture", "Kernel", "Desktop" };
    const values = [_][]const u8{ "0.1.0", "Intel 64-bit / x86_64", "Zest + CitrusFS", "Peel + native apps" };
    for (keys, values, 0..) |key, value, i| {
        const y = 149 + @as(i32, @intCast(i)) * 27;
        ui.label(&s, key, 39, y, 1, 0x778397);
        ui.label(&s, value, 169, y, 1, 0x253247);
        if (i < 3) s.fill(.{ .x = 39, .y = y + 18, .w = 342, .h = 1 }, 0xEEF1F6);
    }
    ui.label(&s, "Independent by design.", 26, 286, 1, 0x556378);
    ui.label(&s, "Built from the kernel up.", 26, 305, 1, 0x778397);
}
fn paint(win: *const libpeel.Window, pointer: ui.Pointer, full: bool) void {
    var s = ui.surface(win);
    s.pixels = &staging;
    const r = if (full) ui.Rect{ .x = 0, .y = 0, .w = win.width, .h = win.height } else done[0].rect;
    var y = r.y * win.scale;
    while (y < r.bottom() * win.scale) : (y += 1) {
        const start: usize = @intCast(y * win.stride + r.x * win.scale);
        const n: usize = @intCast(r.w * win.scale);
        @memcpy(staging[start..][0..n], background[start..][0..n]);
    }
    s.rounded(done[0].rect, 10, if (pointer.pressed == 1) 0x2765C3 else if (pointer.hover == 1) 0x4A87E9 else 0x397BE8, 255);
    ui.label(&s, "Done", 320, 296, 1, 0xFFFFFF);
    ui.publishRegion(win, &staging, r);
    if (pulp.desktop_profile) pulp.puts("about: painted\n");
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("About Orange OS", 420, 338, 440, 220) catch pulp.exit(1);
    var pointer: ui.Pointer = .{};
    prepare(&win);
    paint(&win, pointer, true);
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
            if (pointer.update(ev.x, ev.y, ev.code, &done) == 1) {
                win.destroy();
                pulp.exit(0);
            }
            dirty = dirty or pointer.visualChanged(old);
        }
        if (dirty and pointer.visualChanged(previous)) paint(&win, pointer, false);
        pulp.sleepMs(16);
    }
}
