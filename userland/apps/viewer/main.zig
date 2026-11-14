//! Image Viewer (docs/design/014, M4): look at PNG, BMP and PPM pictures.
//!
//! Opened from Files (or Spotlight) with a picture, it shows it fitted to
//! the window; the arrow keys step through the other pictures in the same
//! folder; + and - zoom, 0 fits, 1 shows it at its own size, and a zoomed
//! picture is dragged around with the pointer. A file that is damaged or of
//! a kind this viewer cannot read says so instead of showing garbage.
const std = @import("std");
const pulp = @import("pulp");
const appkit = @import("appkit");
const ui = appkit.ui;
const K = appkit.K;

const BAR: i32 = ui.Metrics.toolbar_h;
const STATUS_H: i32 = 26;
const CANVAS: u32 = 0xE9EBEF;
const ZOOMS = [_]u32{ 10, 25, 50, 75, 100, 150, 200, 300, 400, 800 };

var app: appkit.App = undefined;
var picture: ?appkit.Picture = null;
var problem: []const u8 = "";
var path_buf: [256]u8 = undefined;
var path_len: usize = 0;
/// 0 fits the window; otherwise a percentage of the picture's own size.
var zoom: u32 = 0;
var pan_x: i32 = 0;
var pan_y: i32 = 0;
var dragging = false;
var drag_x: i32 = 0;
var drag_y: i32 = 0;
/// The pictures in the same folder, for the arrow keys.
var siblings: [64][128]u8 = undefined;
var sibling_len: [64]u8 = undefined;
var sibling_count: usize = 0;
var sibling_index: usize = 0;

fn path() []const u8 {
    return path_buf[0..path_len];
}
fn isImage(name: []const u8) bool {
    inline for (.{ ".png", ".bmp", ".ppm" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}
fn folder() []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path(), '/') orelse return "/";
    return if (cut == 0) "/" else path()[0..cut];
}

fn canvas() ui.Rect {
    return .{ .x = 0, .y = BAR, .w = app.width(), .h = app.height() - BAR - STATUS_H };
}
fn toolButton(i: usize) ui.Rect {
    // Zoom out, zoom in, fit; right-aligned.
    return .{ .x = app.width() - 16 - @as(i32, @intCast(3 - i)) * 34, .y = 12, .w = 28, .h = 28 };
}

/// The picture's size on screen, in points.
fn shownSize() [2]i32 {
    const p = picture orelse return .{ 0, 0 };
    const c = canvas();
    if (zoom == 0) return appkit.image.fit(p.img.width, p.img.height, c.w - 32, c.h - 32, 100);
    return .{ @intCast(@max(1, @as(u64, p.img.width) * zoom / 100)), @intCast(@max(1, @as(u64, p.img.height) * zoom / 100)) };
}
fn shownPercent() u32 {
    const p = picture orelse return 100;
    return @intCast(@as(u64, @intCast(shownSize()[0])) * 100 / p.img.width);
}
fn clampPan() void {
    const size = shownSize();
    const c = canvas();
    const max_x: i32 = @max(0, @divTrunc(size[0] - c.w, 2) + 16);
    const max_y: i32 = @max(0, @divTrunc(size[1] - c.h, 2) + 16);
    pan_x = std.math.clamp(pan_x, -max_x, max_x);
    pan_y = std.math.clamp(pan_y, -max_y, max_y);
}

fn listSiblings() void {
    sibling_count = 0;
    var entries: [64]pulp.DirEntry = undefined;
    var skip: usize = 0;
    const dir = folder();
    while (sibling_count < siblings.len) {
        const n = pulp.readdirPage(dir, &entries, skip) catch break;
        for (entries[0..n]) |*e| {
            const name = e.nameSlice();
            if (e.isDir() or name.len == 0 or name[0] == '.' or !isImage(name) or sibling_count == siblings.len) continue;
            @memcpy(siblings[sibling_count][0..name.len], name);
            sibling_len[sibling_count] = @intCast(name.len);
            sibling_count += 1;
        }
        skip += n;
        if (n < entries.len) break;
    }
    // By name, so Left and Right go in the order Files shows.
    for (1..sibling_count) |i| {
        var j = i;
        while (j > 0 and std.mem.order(u8, siblings[j][0..sibling_len[j]], siblings[j - 1][0..sibling_len[j - 1]]) == .lt) : (j -= 1) {
            std.mem.swap([128]u8, &siblings[j], &siblings[j - 1]);
            std.mem.swap(u8, &sibling_len[j], &sibling_len[j - 1]);
        }
    }
    const name = appkit.basename(path());
    sibling_index = 0;
    for (0..sibling_count) |i| if (std.mem.eql(u8, siblings[i][0..sibling_len[i]], name)) {
        sibling_index = i;
    };
}

fn open(p: []const u8, relist: bool) void {
    if (picture) |*old| old.unload();
    picture = null;
    problem = "";
    zoom = 0;
    pan_x = 0;
    pan_y = 0;
    path_len = @min(p.len, path_buf.len);
    std.mem.copyForwards(u8, path_buf[0..path_len], p[0..path_len]);
    app.win.setTitle(appkit.basename(path()));
    if (appkit.Picture.load(path(), 0xFFFFFF)) |loaded| {
        picture = loaded;
        pulp.print("viewer: opened {s}, {d}x{d}\n", .{ path(), loaded.img.width, loaded.img.height });
    } else |err| {
        problem = appkit.Picture.problem(err);
        pulp.print("viewer: cannot show {s}: {s}\n", .{ path(), problem });
    }
    if (relist) listSiblings();
}

fn step(forward: bool) void {
    if (sibling_count < 2) return;
    sibling_index = if (forward) (sibling_index + 1) % sibling_count else (sibling_index + sibling_count - 1) % sibling_count;
    var buf: [400]u8 = undefined;
    const dir = folder();
    const next = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, if (dir.len == 1) "" else "/", siblings[sibling_index][0..sibling_len[sibling_index]] }) catch return;
    open(next, false);
}

fn zoomBy(in: bool) void {
    if (picture == null) return;
    const now = shownPercent();
    var next: u32 = now;
    if (in) {
        for (ZOOMS) |z| if (z > now) {
            next = z;
            break;
        };
    } else {
        var i = ZOOMS.len;
        while (i > 0) {
            i -= 1;
            if (ZOOMS[i] < now) {
                next = ZOOMS[i];
                break;
            }
        }
    }
    if (next == now) return;
    zoom = next;
    clampPan();
    pulp.print("viewer: zoom {d}%\n", .{zoom});
}

fn command(id: u32) void {
    switch (id) {
        1 => zoomBy(false),
        2 => zoomBy(true),
        3 => {
            zoom = 0;
            pan_x = 0;
            pan_y = 0;
        },
        4 => if (picture != null) {
            zoom = 100;
            clampPan();
        },
        5 => step(false),
        6 => step(true),
        else => {},
    }
}

fn paint() void {
    var s = app.surface();
    const W = app.width();
    const H = app.height();
    const T = ui.Tone;
    const c = canvas();
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, CANVAS);
    if (picture) |*p| {
        const size = shownSize();
        const dest = ui.Rect{ .x = c.x + @divTrunc(c.w - size[0], 2) + pan_x, .y = c.y + @divTrunc(c.h - size[1], 2) + pan_y, .w = size[0], .h = size[1] };
        s.setClip(c);
        // A soft shadow under the picture, then the picture.
        s.rounded(.{ .x = dest.x - 1, .y = dest.y + 2, .w = dest.w + 2, .h = dest.h + 2 }, 2, 0x000000, 30);
        appkit.drawImage(&s, &p.img, dest);
        s.setClip(.{ .x = 0, .y = 0, .w = W, .h = H });
    } else {
        ui.icon(&s, .dock_viewer, @divTrunc(W - 72, 2), c.y + @max(16, @divTrunc(c.h - 150, 2)), 72);
        const text = if (problem.len > 0) problem else "Open a picture from Files to see it here.";
        const shown = ui.fitting(text, W - 48);
        ui.label(&s, shown, @divTrunc(W - ui.textWidth(shown, 1), 2), c.y + @max(16, @divTrunc(c.h - 150, 2)) + 96, 1, if (problem.len > 0) 0xB05251 else T.secondary);
    }
    // Toolbar: the name at the left (after the window buttons), zoom at the right.
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = BAR }, T.toolbar);
    s.fill(.{ .x = 0, .y = BAR - 1, .w = W, .h = 1 }, T.hairline);
    const name = if (path_len == 0) "Image Viewer" else appkit.basename(path());
    var name_buf: [140]u8 = undefined;
    ui.label(&s, ui.elide(&name_buf, name, toolButton(0).x - 16 - ui.Metrics.buttons_w), ui.Metrics.buttons_w, 22, 1, T.text);
    const icons = [3]ui.Icon{ .sym_minus, .sym_plus, .sym_image };
    for (0..3) |i| {
        var st = ui.ControlState.of(app.pointer, @intCast(i + 1));
        st.enabled = picture != null;
        st.selected = i == 2 and zoom == 0 and picture != null;
        ui.toolbarButton(&s, toolButton(i), icons[i], st);
    }
    s.fill(.{ .x = 0, .y = H - STATUS_H, .w = W, .h = STATUS_H }, T.toolbar);
    s.fill(.{ .x = 0, .y = H - STATUS_H, .w = W, .h = 1 }, T.hairline);
    if (picture) |*p| {
        var buf: [96]u8 = undefined;
        var of_buf: [24]u8 = undefined;
        const of = if (sibling_count > 1) std.fmt.bufPrint(&of_buf, "  /  {d} of {d}", .{ sibling_index + 1, sibling_count }) catch "" else "";
        const text = std.fmt.bufPrint(&buf, "{d} x {d} pixels  /  {s}  /  {d}%{s}", .{ p.img.width, p.img.height, switch (p.img.format) {
            .png => "PNG",
            .bmp => "BMP",
            .ppm => "PPM",
        }, shownPercent(), of }) catch "";
        ui.label(&s, ui.fitting(text, W - 32), 16, H - STATUS_H + 9, 1, T.secondary);
    }
    app.presentAll();
    if (pulp.desktop_profile) pulp.puts("viewer: painted\n");
}

const MENU =
    "MView\n" ++
    "I2 Zoom In\t+\n" ++
    "I1 Zoom Out\t-\n" ++
    "I3 Fit to Window\t0\n" ++
    "I4 Actual Size\t1\n" ++
    "-\n" ++
    "I5 Previous Picture\tLeft\n" ++
    "I6 Next Picture\tRight\n";

export fn _start() callconv(.c) noreturn {
    app = appkit.App.open(.{
        .title = "Image Viewer",
        .app = appkit.proto.App.viewer,
        .width = 720,
        .height = 520,
        .x = 280,
        .y = 100,
        .min_w = 360,
        .min_h = 260,
        .bar_height = BAR,
        .menu = MENU,
    });
    paint();
    while (true) {
        var dirty = false;
        while (app.next()) |event| switch (event) {
            .close => app.quit(),
            .resized => {
                clampPan();
                dirty = true;
            },
            .open_file => |p| {
                open(p, true);
                dirty = true;
            },
            .menu => |id| {
                command(id);
                dirty = true;
            },
            .wheel => |steps| {
                zoomBy(steps < 0);
                dirty = true;
            },
            .key => |k| if (k.down) {
                dirty = true;
                switch (k.code) {
                    K.left => command(5),
                    K.right => command(6),
                    else => switch (k.ch) {
                        '+', '=' => command(2),
                        '-' => command(1),
                        '0' => command(3),
                        '1' => command(4),
                        else => dirty = false,
                    },
                }
            },
            .mouse => |m| {
                const before = app.pointer;
                var targets: [3]ui.Button = undefined;
                for (0..3) |i| targets[i] = .{ .id = @intCast(i + 1), .rect = toolButton(i) };
                const action = app.click(m, &targets);
                if (action != 0) {
                    command(action);
                    dirty = true;
                }
                if (app.pointer.visualChanged(before)) dirty = true;
                if (m.pressed and app.pointer.pressed == 0) {
                    if (m.y >= 0 and m.y < BAR) {
                        app.win.requestMove();
                    } else if (canvas().contains(m.x, m.y) and zoom != 0) {
                        dragging = true;
                        drag_x = m.x - pan_x;
                        drag_y = m.y - pan_y;
                    }
                }
                if (dragging and m.buttons & 1 != 0) {
                    const old = [2]i32{ pan_x, pan_y };
                    pan_x = m.x - drag_x;
                    pan_y = m.y - drag_y;
                    clampPan();
                    if (old[0] != pan_x or old[1] != pan_y) dirty = true;
                }
                if (m.released) dragging = false;
            },
            else => {},
        };
        if (dirty) paint();
        app.idle();
    }
}
