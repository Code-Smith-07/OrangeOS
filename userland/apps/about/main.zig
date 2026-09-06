//! About Orange OS: an original frosted system identity card.
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const done = [_]ui.Button{.{ .id = 1, .rect = .{ .x = 280, .y = 282, .w = 112, .h = 36 } }};
fn paint(win: *const libpeel.Window, pointer: ui.Pointer) void {
    var s = ui.surface(win);
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 420, .h = 338 }, 0, 0xF8E8E3, 0xE8E6F7);
    s.frost(.{ .x = 22, .y = 20, .w = 376, .h = 114 }, 22, 0xFFFFFF, 100);
    ui.icon(&s, .welcome, 37, 35, 86);
    ui.label(&s, "Orange OS", 141, 47, 2, 0x51405C);
    ui.label(&s, "Daybreak desktop", 142, 84, 1, 0x9A7A91);
    s.frost(.{ .x = 22, .y = 148, .w = 376, .h = 119 }, 18, 0xFFFFFF, 130);
    ui.label(&s, "Version 0.1.0  /  x86_64", 38, 164, 1, 0x5D5775);
    ui.label(&s, "Zest kernel + CitrusFS storage", 38, 190, 1, 0x82798F);
    ui.label(&s, "Peel display + native applications", 38, 214, 1, 0x82798F);
    ui.label(&s, "An independent OS, made from scratch.", 38, 242, 1, 0x9D778F);
    ui.label(&s, "Made for possibility.", 26, 297, 1, 0x9A8DA6);
    ui.gradient(&s, done[0].rect, 12, if (pointer.pressed == 1) 0x7560AA else if (pointer.hover == 1) 0xAD95DD else 0x9D87CC, 0x7E6AAA);
    ui.label(&s, "Done", 320, 295, 1, 0xFFFFFF);
    win.commitAll();
}
export fn _start() callconv(.c) noreturn {
    const win = libpeel.createWindow("About Orange OS", 420, 338, 440, 220) catch pulp.exit(1);
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
            if (pointer.update(ev.x, ev.y, ev.code, &done) == 1) {
                win.destroy();
                pulp.exit(0);
            }
            dirty = dirty or old.hover != pointer.hover or old.down != pointer.down;
        }
        if (dirty) paint(&win, pointer);
        pulp.sleepMs(16);
    }
}
