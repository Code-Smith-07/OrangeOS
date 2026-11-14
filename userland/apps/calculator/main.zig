//! Calculator (docs/design/014, M4): a pocket calculator with raised keys.
//! Each key is one colour family, shaped by light: a reflection across the
//! top, a bright upper edge, a soft shadow underneath, and it sinks a point
//! when pressed. The arithmetic lives in calc.zig.
const std = @import("std");
const pulp = @import("pulp");
const appkit = @import("appkit");
const ui = appkit.ui;
const K = appkit.K;
const calc = @import("calc.zig");

const W: i32 = 244;
const H: i32 = 358;
const PAD: i32 = 12;
const KEY_W: i32 = 49;
const KEY_H: i32 = 44;
const GAP: i32 = 8;
const KEYS_Y: i32 = 94;

const BODY: u32 = 0x25282E;
const DIGIT: u32 = 0x4B4F58;
const FUNCTION: u32 = 0x6C717B;
const OPERATOR: u32 = 0xF28A1E;

const Key = struct { key: u8, label: []const u8, color: u32, col: i32, row: i32, span: i32 = 1 };
const KEYS = [_]Key{
    .{ .key = 'C', .label = "AC", .color = FUNCTION, .col = 0, .row = 0 },
    .{ .key = 'S', .label = "+/-", .color = FUNCTION, .col = 1, .row = 0 },
    .{ .key = '%', .label = "%", .color = FUNCTION, .col = 2, .row = 0 },
    .{ .key = '/', .label = "/", .color = OPERATOR, .col = 3, .row = 0 },
    .{ .key = '7', .label = "7", .color = DIGIT, .col = 0, .row = 1 },
    .{ .key = '8', .label = "8", .color = DIGIT, .col = 1, .row = 1 },
    .{ .key = '9', .label = "9", .color = DIGIT, .col = 2, .row = 1 },
    .{ .key = '*', .label = "x", .color = OPERATOR, .col = 3, .row = 1 },
    .{ .key = '4', .label = "4", .color = DIGIT, .col = 0, .row = 2 },
    .{ .key = '5', .label = "5", .color = DIGIT, .col = 1, .row = 2 },
    .{ .key = '6', .label = "6", .color = DIGIT, .col = 2, .row = 2 },
    .{ .key = '-', .label = "-", .color = OPERATOR, .col = 3, .row = 2 },
    .{ .key = '1', .label = "1", .color = DIGIT, .col = 0, .row = 3 },
    .{ .key = '2', .label = "2", .color = DIGIT, .col = 1, .row = 3 },
    .{ .key = '3', .label = "3", .color = DIGIT, .col = 2, .row = 3 },
    .{ .key = '+', .label = "+", .color = OPERATOR, .col = 3, .row = 3 },
    .{ .key = '0', .label = "0", .color = DIGIT, .col = 0, .row = 4, .span = 2 },
    .{ .key = '.', .label = ".", .color = DIGIT, .col = 2, .row = 4 },
    .{ .key = '=', .label = "=", .color = OPERATOR, .col = 3, .row = 4 },
};

var app: appkit.App = undefined;
var state = calc.Calc{};
/// A key shown pressed because the keyboard typed it, and until when.
var flash: ?usize = null;
var flash_until: u64 = 0;

fn keyRect(k: Key) ui.Rect {
    return .{ .x = PAD + k.col * (KEY_W + GAP), .y = KEYS_Y + k.row * (KEY_H + GAP), .w = KEY_W * k.span + GAP * (k.span - 1), .h = KEY_H };
}
fn displayRect() ui.Rect {
    return .{ .x = PAD, .y = 12, .w = W - PAD * 2, .h = 70 };
}

fn paintKey(s: *ui.Surface, index: usize) void {
    const k = KEYS[index];
    var r = keyRect(k);
    const down = (app.pointer.pressed == index + 1 and app.pointer.hover == index + 1) or flash == index;
    // The pending operator stays lit, as on a real calculator.
    const lit = k.color == OPERATOR and k.key != '=' and state.pendingSymbol() == k.key and !state.typing;
    s.fill(.{ .x = r.x - 1, .y = r.y - 1, .w = r.w + 2, .h = r.h + 5 }, BODY);
    if (!down) s.rounded(.{ .x = r.x, .y = r.y + 3, .w = r.w, .h = r.h }, 11, 0x000000, 90);
    if (down) r.y += 2;
    var color = if (lit) ui.gfx.lerp(k.color, 0xFFFFFF, 190) else k.color;
    if (down) color = ui.gfx.lerp(color, 0x000000, 46);
    s.rounded(r, 11, color, 255);
    // Light on a glossy cap: a reflection over the top half and a bright
    // upper edge; the lower edge falls into shade.
    if (!down) {
        s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = @divTrunc(r.h, 2) }, 10, 0xFFFFFF, 22);
        s.rounded(.{ .x = r.x + 6, .y = r.y + 1, .w = r.w - 12, .h = 1 }, 0, 0xFFFFFF, 70);
    }
    s.rounded(.{ .x = r.x + 6, .y = r.bottom() - 2, .w = r.w - 12, .h = 1 }, 0, 0x000000, 46);
    const scale: i32 = if (k.label.len > 1) 1 else 2;
    const ink: u32 = if (lit) OPERATOR else 0xFFFFFF;
    const tw = ui.textWidth(k.label, scale);
    ui.label(s, k.label, r.x + @divTrunc(r.w - tw, 2), r.y + @divTrunc(r.h, 2) - (if (scale == 2) @as(i32, 8) else 4), scale, ink);
}

fn paintDisplay(s: *ui.Surface) void {
    const d = displayRect();
    // An inset glass window: dark, with a shaded top lip and a lit lower rim.
    s.rounded(.{ .x = d.x - 1, .y = d.y - 1, .w = d.w + 2, .h = d.h + 2 }, 11, 0x000000, 120);
    s.rounded(d, 10, 0x14171B, 255);
    s.rounded(.{ .x = d.x + 8, .y = d.bottom(), .w = d.w - 16, .h = 1 }, 0, 0xFFFFFF, 26);
    var buf: [32]u8 = undefined;
    const text = state.display(&buf);
    // The largest size at which the whole number fits: never cut a digit.
    var scale: i32 = 3;
    while (scale > 1 and ui.textWidth(text, scale) > d.w - 24) scale -= 1;
    const shown = ui.fitting(text, if (scale == 1) d.w - 24 else 100000);
    ui.label(s, shown, d.right() - 12 - ui.textWidth(shown, scale), d.y + 44 - scale * 5, scale, 0xF2F5F8);
    if (state.pendingSymbol()) |op| {
        const symbol: []const u8 = switch (op) {
            '*' => "x",
            '/' => "/",
            '+' => "+",
            else => "-",
        };
        ui.label(s, symbol, d.x + 12, d.y + 12, 1, OPERATOR);
    }
}

fn paintAll() void {
    var s = app.surface();
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, BODY);
    s.rounded(.{ .x = 0, .y = 0, .w = W, .h = 1 }, 0, 0xFFFFFF, 26);
    paintDisplay(&s);
    for (0..KEYS.len) |i| paintKey(&s, i);
    app.presentAll();
    if (pulp.desktop_profile) pulp.puts("calculator: painted\n");
}

fn press(key: u8) void {
    if (!state.press(key)) return;
    var buf: [32]u8 = undefined;
    pulp.print("calculator: {c} -> {s}\n", .{ key, state.display(&buf) });
}

fn keyFor(k: appkit.Key) ?u8 {
    if (k.code == K.enter) return '=';
    if (k.code == K.esc) return 'C';
    if (k.code == K.backspace) return 'B';
    return switch (k.ch) {
        '0'...'9', '.', '+', '-', '*', '/', '=', '%' => k.ch,
        'x', 'X' => '*',
        'c', 'C' => 'C',
        else => null,
    };
}

export fn _start() callconv(.c) noreturn {
    app = appkit.App.open(.{
        .title = "Calculator",
        .app = appkit.proto.App.calculator,
        .width = W,
        .height = H,
        .x = 900,
        .y = 250,
        .resizable = false,
        .menu = "MEdit\nI1 Clear\tEsc\n",
    });
    var targets: [KEYS.len]ui.Button = undefined;
    for (KEYS, 0..) |k, i| targets[i] = .{ .id = @intCast(i + 1), .rect = keyRect(k) };
    paintAll();
    while (true) {
        var dirty = false;
        if (flash != null and pulp.uptimeMs() >= flash_until) {
            flash = null;
            dirty = true;
        }
        while (app.next()) |event| switch (event) {
            .close => app.quit(),
            .menu => |id| if (id == 1) {
                press('C');
                dirty = true;
            },
            .key => |k| if (k.down) if (keyFor(k)) |key| {
                press(key);
                for (KEYS, 0..) |candidate, i| if (candidate.key == key) {
                    flash = i;
                    flash_until = pulp.uptimeMs() + 110;
                };
                dirty = true;
            },
            .mouse => |m| {
                const before = app.pointer;
                const action = app.click(m, &targets);
                if (action != 0) press(KEYS[action - 1].key);
                dirty = dirty or action != 0 or app.pointer.visualChanged(before);
            },
            else => {},
        };
        if (dirty) paintAll();
        app.idle();
    }
}
