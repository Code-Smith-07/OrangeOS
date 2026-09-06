//! Peel — the Orange OS display server.
//!
//! Owns the framebuffer, composites windows, and routes input. It is an
//! ordinary ring 3 process holding no special authority beyond the framebuffer
//! capability the kernel granted it: if Peel crashes, Seed restarts it and the
//! system carries on.
//!
//! The frame loop only redraws damage. Recompositing the whole screen every
//! frame would work at this resolution, but it would not survive a Retina
//! panel, and building the discipline in from the start is cheaper than
//! retrofitting it.

const pulp = @import("pulp");
const libpeel = @import("libpeel");
const proto = libpeel.proto;
const gfx = @import("gfx");
const ui = @import("ui");
const font = @import("font.zig");
const desktop = @import("desktop.zig");
const pointer = @import("pointer.zig");

const Rect = gfx.Rect;
const Color = gfx.Color;

// ── Theme ───────────────────────────────────────────────────────────────────

const ORANGE: Color = 0xFF8C1A;
const WIN_BG: Color = 0xF5F4FC;
const WIN_TITLE: Color = 0xE8E7F2;
const WIN_TITLE_ACTIVE: Color = 0xF7F5FC;
const TEXT: Color = 0x33334C;
const TEXT_DIM: Color = 0x77758C;

const TITLE_H: i32 = 38;
const BORDER_W: i32 = 1;
const SHADOW: i32 = 16;

// ── Windows ─────────────────────────────────────────────────────────────────

const MAX_WINDOWS = 8;

const Window = struct {
    rect: Rect,
    title_buf: [48]u8 = undefined,
    title_len: usize = 0,
    accent: Color,
    visible: bool = true,
    zoomed: bool = false,
    restore_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    /// A client-backed window owns a shared buffer the client renders into.
    /// Peel only ever reads it. A window with no buffer is drawn by Peel
    /// itself, which is how the boot placeholder works before any client
    /// has connected.
    pixels: ?[*]const u32 = null,
    client_w: i32 = 0,
    client_h: i32 = 0,
    reply_port: i64 = -1,
    buffer_handle: i64 = -1,
    owner_pid: i64 = -1,
    closable: bool = true,
    id: u32 = 0,
    revision: u64 = 0,

    fn title(self: *const Window) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn setTitle(self: *Window, t: []const u8) void {
        self.title_len = @min(t.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], t[0..self.title_len]);
    }

    /// Where the client's content sits inside the frame.
    fn contentRect(self: *const Window) Rect {
        return .{
            .x = self.rect.x + BORDER_W,
            .y = self.rect.y + TITLE_H,
            .w = self.rect.w - BORDER_W * 2,
            .h = self.rect.h - TITLE_H - BORDER_W,
        };
    }

    fn titleBar(self: *const Window) Rect {
        return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w, .h = TITLE_H };
    }

    fn closeButton(self: *const Window) Rect {
        return self.control(0);
    }

    fn control(self: *const Window, index: i32) Rect {
        return .{ .x = self.rect.x + 10 + index * 22, .y = self.rect.y + 7, .w = 22, .h = 24 };
    }

    /// The area the compositor must repaint for this window: its frame plus
    /// the shadow that falls outside it.
    fn damageRect(self: *const Window) Rect {
        return .{
            .x = self.rect.x - SHADOW,
            .y = self.rect.y - SHADOW,
            .w = self.rect.w + SHADOW * 2,
            .h = self.rect.h + SHADOW * 2 + 8,
        };
    }
};

var windows: [MAX_WINDOWS]Window = undefined;
var window_count: usize = 0;
/// Back to front. The last entry is on top and has focus.
var z_order: [MAX_WINDOWS]usize = undefined;

var next_window_id: u32 = 1;

fn addWindow(r: Rect, title: []const u8, accent: Color) ?usize {
    if (window_count >= MAX_WINDOWS) return null;
    const idx = window_count;
    if (activeWindow()) |old| addDamage(windows[old].damageRect());
    windows[idx] = .{ .rect = r, .accent = accent, .id = next_window_id };
    windows[idx].setTitle(title);
    next_window_id += 1;
    z_order[idx] = idx;
    window_count += 1;
    chromeDamage();
    return idx;
}

fn findWindowById(id: u32) ?usize {
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (windows[i].id == id) return i;
    }
    return null;
}

/// Move a window to the top of the stack.
fn raise(index: usize) void {
    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (z_order[i] != index) continue;
        var j = i;
        while (j + 1 < window_count) : (j += 1) z_order[j] = z_order[j + 1];
        z_order[window_count - 1] = index;
        return;
    }
}

/// Focus a window and repaint both title bars whose active state changed.
fn focusWindow(index: usize) void {
    if (activeWindow()) |previous| addDamage(windows[previous].damageRect());
    windows[index].visible = true;
    raise(index);
    addDamage(windows[index].damageRect());
    chromeDamage();
}

fn activeWindow() ?usize {
    var i = window_count;
    while (i > 0) {
        i -= 1;
        const idx = z_order[i];
        if (windows[idx].visible) return idx;
    }
    return null;
}

var shell: desktop.State = .{};
var wallpaper: ?gfx.Surface = null;
var pending_apps: [6]i64 = .{ -1, -1, -1, -1, -1, -1 };
var shell_pressed: ?u16 = null;
var control_pressed: ?struct { id: u32, control: i32 } = null;
var desktop_hidden: [MAX_WINDOWS]u32 = [_]u32{0} ** MAX_WINDOWS;
var desktop_hidden_count: usize = 0;

fn chromeDamage() void {
    addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
    const d = desktop.dockRect(&screen);
    addDamage(.{ .x = d.x - 12, .y = d.y - 45, .w = d.w + 24, .h = d.h + 65 });
    if (shell.popup != .none) addDamage(desktop.popupRect(&screen, shell.popup));
}

fn appIndex(title: []const u8) usize {
    if (@import("std").mem.eql(u8, title, "Files")) return 4;
    if (@import("std").mem.eql(u8, title, "Trash")) return 5;
    if (title.len >= 7 and @import("std").mem.eql(u8, title[0..7], "Squeeze")) return 1;
    if (@import("std").mem.eql(u8, title, "clock")) return 2;
    if (title.len >= 5 and @import("std").mem.eql(u8, title[0..5], "About")) return 3;
    return 0;
}

fn syncShell() void {
    shell.active = if (activeWindow()) |idx| windows[idx].title() else "Desktop";
    shell.running = .{ false, false, false, false, false, false };
    shell.count = window_count;
    for (0..window_count) |i| {
        const app = appIndex(windows[i].title());
        shell.running[app] = true;
        shell.items[i] = .{ .id = windows[i].id, .revision = windows[i].revision, .title = windows[i].title(), .hidden = !windows[i].visible, .app = app, .pixels = windows[i].pixels, .width = windows[i].client_w * screen.scale, .height = windows[i].client_h * screen.scale };
    }
}

fn launchApp(app: usize, new_instance: bool) void {
    if (!new_instance) {
        var i = window_count;
        while (i > 0) {
            i -= 1;
            const idx = z_order[i];
            if (appIndex(windows[idx].title()) == app) {
                focusWindow(idx);
                return;
            }
        }
        if (pending_apps[app] > 0) {
            const ended = pulp.waitNoHang(pending_apps[app]) catch @as(?i64, 0);
            if (ended == null) return;
        }
    }
    if (window_count == MAX_WINDOWS) {
        shell.notice = "Window limit reached. Close a window.";
        return;
    }
    const paths = [_][]const u8{ "/bin/grove", "/bin/squeeze", "/bin/clock", "/bin/about", "/bin/files", "/bin/trash" };
    pending_apps[app] = pulp.spawn(paths[app]) catch {
        shell.notice = "Could not start the application.";
        return;
    };
    pulp.print("desktop: launched {s}\n", .{paths[app]});
}

fn toggleDesktop() void {
    if (desktop_hidden_count > 0) {
        for (desktop_hidden[0..desktop_hidden_count]) |id| {
            if (findWindowById(id)) |idx| windows[idx].visible = true;
        }
        desktop_hidden_count = 0;
    } else {
        for (0..window_count) |i| if (windows[i].visible) {
            desktop_hidden[desktop_hidden_count] = windows[i].id;
            desktop_hidden_count += 1;
            windows[i].visible = false;
        };
    }
    addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
}

fn zoomWindow(idx: usize) void {
    const w = &windows[idx];
    addDamage(w.damageRect());
    if (w.zoomed) {
        w.rect = w.restore_rect;
    } else {
        w.restore_rect = w.rect;
        w.rect = .{ .x = 12, .y = desktop.BAR_H + 12, .w = screen.width - 24, .h = screen.height - desktop.BAR_H - desktop.DOCK_H - 42 };
    }
    w.zoomed = !w.zoomed;
    addDamage(w.damageRect());
    pulp.print("desktop: zoom window {d} = {d}\n", .{ w.id, @intFromBool(w.zoomed) });
}

fn shellAction(action: u16) void {
    desktop.invalidateOverview();
    shell.notice = "";
    const old = shell.popup;
    shell.popup = .none;
    switch (action) {
        1...4 => launchApp(action - 1, false),
        desktop.Action.files => launchApp(4, false),
        desktop.Action.trash => launchApp(5, false),
        desktop.Action.menu => shell.popup = if (old == .menu) .none else .menu,
        desktop.Action.overview => shell.popup = if (old == .overview) .none else .overview,
        desktop.Action.settings => shell.popup = if (old == .settings) .none else .settings,
        desktop.Action.desktop => toggleDesktop(),
        desktop.Action.new_terminal => launchApp(1, true),
        desktop.Action.wallpaper...desktop.Action.wallpaper + 2 => {
            shell.palette = action - desktop.Action.wallpaper;
            rebuildWallpaper();
            shell.popup = .settings;
            pulp.print("desktop: wallpaper {d}\n", .{shell.palette});
        },
        desktop.Action.window...desktop.Action.window + MAX_WINDOWS - 1 => {
            const idx = action - desktop.Action.window;
            if (idx < window_count) focusWindow(idx);
        },
        else => {},
    }
    addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
}

/// Topmost window containing the point, searching front to back.
fn windowAt(x: i32, y: i32) ?usize {
    var i: usize = window_count;
    while (i > 0) {
        i -= 1;
        const idx = z_order[i];
        if (windows[idx].visible and windows[idx].rect.contains(x, y)) return idx;
    }
    return null;
}

fn clientWindowAt(x: i32, y: i32) ?usize {
    const idx = windowAt(x, y) orelse return null;
    if (!windows[idx].contentRect().contains(x, y)) return null;
    return idx;
}

// ── Damage ──────────────────────────────────────────────────────────────────

var damage: gfx.Damage = .{};
var overview_damage: gfx.Damage = .{};

fn addDamage(r: Rect) void {
    damage.add(r);
}

fn clearDamage() void {
    damage.count = 0;
    overview_damage.count = 0;
}

// ── Cursor ──────────────────────────────────────────────────────────────────

const CURSOR_W: i32 = 20;
const CURSOR_H: i32 = 20;

var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var prev_cursor_x: i32 = 0;
var prev_cursor_y: i32 = 0;
// The scene buffer never contains the cursor. Restore its old front-buffer
// footprint from the finished scene, then draw only the new pointer.
var presented_cursor_x: i32 = 0;
var presented_cursor_y: i32 = 0;
var cursor_dirty = false;

fn cursorRect(x: i32, y: i32) Rect {
    return .{ .x = x, .y = y, .w = CURSOR_W, .h = CURSOR_H };
}

fn drawCursor(s: *const gfx.Surface, x: i32, y: i32) void {
    ui.icon(s, .pointer, x, y, 20);
}

// ── Painting ────────────────────────────────────────────────────────────────

/// Peel draws a complete damage region off-screen, then copies only the final
/// pixels to the hardware framebuffer. Painting layers directly on the visible
/// framebuffer exposed the wallpaper/frame/content sequence as interaction
/// flicker, especially under QEMU's slow software display path.
var screen: gfx.Surface = undefined;
var front: gfx.Surface = undefined;
var back_handle: i64 = -1;
// A cursor/chrome-free snapshot of the layers underneath the dragged window.
// Client commits, window-stack changes and keyboard/shell actions invalidate it.
var drag_backdrop: ?gfx.Surface = null;
var drag_backdrop_id: ?u32 = null;
var drag_backdrop_valid = false;

fn rebuildWallpaper() void {
    if (wallpaper) |*s| {
        var y: i32 = 0;
        while (y < s.height * s.scale) : (y += 1) {
            var x: i32 = 0;
            while (x < s.width * s.scale) : (x += 1) s.putPhysical(x, y, desktop.wallpaperPixel(x, y, s.width * s.scale, s.height * s.scale, shell.palette));
        }
    }
}

fn paintWallpaper(clip: Rect) void {
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    const area = Rect.intersect(clip, full);
    if (area.isEmpty()) return;

    var y = area.y * screen.scale;
    while (y < area.bottom() * screen.scale) : (y += 1) {
        if (wallpaper) |s| {
            const start: usize = @intCast(y * screen.stride + area.x * screen.scale);
            const len: usize = @intCast(area.w * screen.scale);
            @memcpy(screen.pixels[start..][0..len], s.pixels[start..][0..len]);
        } else {
            var x = area.x * screen.scale;
            while (x < area.right() * screen.scale) : (x += 1) screen.putPhysical(x, y, desktop.wallpaperPixel(x, y, screen.width * screen.scale, screen.height * screen.scale, shell.palette));
        }
    }
}

fn paintWindow(w: *const Window, active: bool, clip: Rect) void {
    if (!w.visible) return;
    if (!Rect.overlaps(w.damageRect(), clip)) return;

    screen.setClip(clip);
    gfx.windowShadow(&screen, w.rect, active);
    // Diffuse the actual underlying desktop before painting opaque content.
    // Limit title writes to the title while rounding the full frame's top edge.
    screen.setClip(Rect.intersect(clip, w.titleBar()));
    screen.frostTop(w.titleBar(), 13, if (active) WIN_TITLE_ACTIVE else WIN_TITLE, if (active) 196 else 172);
    if (w.pixels != null) {
        // Clients replace the interior. Only the border/corner fringe needs
        // a frame background; avoid shading millions of soon-overwritten pixels.
        for ([_]Rect{
            .{ .x = w.rect.x, .y = w.rect.y + TITLE_H, .w = 1, .h = w.rect.h - TITLE_H },
            .{ .x = w.rect.right() - 1, .y = w.rect.y + TITLE_H, .w = 1, .h = w.rect.h - TITLE_H },
            .{ .x = w.rect.x, .y = w.rect.bottom() - 14, .w = w.rect.w, .h = 14 },
        }) |strip| {
            screen.setClip(Rect.intersect(clip, strip));
            screen.rounded(w.rect, 13, WIN_BG, 255);
        }
    } else {
        screen.setClip(Rect.intersect(clip, .{ .x = w.rect.x, .y = w.rect.y + TITLE_H, .w = w.rect.w, .h = w.rect.h - TITLE_H }));
        screen.rounded(w.rect, 13, WIN_BG, 255);
    }
    screen.setClip(clip);
    screen.rounded(.{ .x = w.rect.x + 14, .y = w.rect.y, .w = w.rect.w - 28, .h = 1 }, 0, 0xFFFFFF, 160);
    screen.rounded(.{ .x = w.rect.x + 1, .y = w.rect.y + TITLE_H - 1, .w = w.rect.w - 2, .h = 1 }, 0, 0x9C95B9, 60);
    const title = w.title()[0..@min(w.title_len, @as(usize, @intCast(@max(1, @divTrunc(w.rect.w - 200, 8)))))];
    font.drawText(&screen, title, w.rect.x + @divTrunc(w.rect.w - font.textWidth(title, 1), 2) + 20, w.rect.y + 16, 1, if (active) TEXT else TEXT_DIM);
    const colors = [_]u32{ 0xFF605C, 0xFFBD44, 0x00CA70 };
    for (0..3) |i| {
        if (i == 0 and !w.closable) continue;
        const c = w.control(@intCast(i));
        screen.circle(c.x + 11, c.y + 12, 7, colors[i]);
        if (dragging == null and c.contains(cursor_x, cursor_y)) {
            ui.icon(&screen, ([_]ui.Icon{ .close, .minimize, .maximize })[i], c.x + 3, c.y + 4, 16);
        }
    }

    // Client content: copy the client's buffer into place. Peel never draws
    // inside a client window, and the client never touches the screen.
    if (w.pixels) |src| {
        const content = w.contentRect();
        const area = Rect.intersect(content, clip);
        if (!area.isEmpty()) {
            const sc = screen.scale;
            var y = area.y * sc;
            while (y < area.bottom() * sc) : (y += 1) {
                if (content.w == w.client_w and content.h == w.client_h and y < (w.rect.bottom() - 14) * sc) {
                    const from: usize = @intCast((y - content.y * sc) * w.client_w * sc + (area.x - content.x) * sc);
                    const to: usize = @intCast(y * screen.stride + area.x * sc);
                    const len: usize = @intCast(area.w * sc);
                    @memcpy(screen.pixels[to..][0..len], src[from..][0..len]);
                    continue;
                }
                const sy = @divTrunc((y - content.y * sc) * w.client_h, @max(1, content.h));
                if (sy < 0 or sy >= w.client_h * sc) continue;
                var x = area.x * sc;
                while (x < area.right() * sc) : (x += 1) {
                    const sx = @divTrunc((x - content.x * sc) * w.client_w, @max(1, content.w));
                    if (sx < 0 or sx >= w.client_w * sc) continue;
                    // Preserve the frame's rounded lower corners when copying
                    // client pixels. The shared client buffer stays rectangular.
                    const dx = @max(@max((w.rect.x + 12) * sc - x, x - (w.rect.right() - 13) * sc), 0);
                    const dy = @max(y - (w.rect.bottom() - 13) * sc, 0);
                    if (dx * dx + dy * dy > 144 * sc * sc) continue;
                    const pixel = src[@intCast(sy * w.client_w * sc + sx)];
                    const dist = dx * dx + dy * dy;
                    if (dist > 144 * sc * sc - 24 * sc) {
                        const alpha: u8 = @intCast(@divTrunc((144 * sc * sc - dist) * 255, 24 * sc));
                        const offset: usize = @intCast(y * screen.stride + x);
                        screen.putPhysical(x, y, gfx.lerp(screen.pixels[offset], pixel, alpha));
                    } else screen.putPhysical(x, y, pixel);
                }
            }
        }
    } else {
        font.drawText(&screen, "waiting for a client...", w.rect.x + 12, w.rect.y + TITLE_H + 14, 1, TEXT_DIM);
    }
}

/// Repaint everything intersecting `area`, back to front.
fn expandedDamage(area: Rect) Rect {
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    var clip = Rect.intersect(area, full);
    if (clip.isEmpty()) return clip;
    syncShell();
    // Fixed-point closure for stacked glass. Underlying layers are always
    // repainted before frost samples them; old glass/cursor pixels never feed
    // the next blur. Keep ordinary client-only damage small.
    while (true) {
        const before = clip;
        for (windows[0..window_count]) |*w| {
            if (w.visible) clip = gfx.expandForGlass(clip, w.titleBar());
        }
        clip = Rect.intersect(desktop.expandDamage(&screen, &shell, clip), full);
        if (clip.x == before.x and clip.y == before.y and clip.w == before.w and clip.h == before.h) break;
    }

    return clip;
}

fn composite(clip: Rect) void {
    if (clip.isEmpty()) return;
    // Everything drawn this frame is confined to the damage region. Window
    // backgrounds and title bars are drawn unclipped by intent - they are
    // whole-rectangle fills - so without this a small commit would blank an
    // entire window and repaint only the damaged strip of its contents.
    screen.setClip(clip);
    defer screen.resetClip();

    const moving = if (dragging) |id| findWindowById(id) else null;
    const can_cache = moving != null and activeWindow() == moving and windows[moving.?].visible and drag_backdrop != null;
    if (can_cache) {
        const id = windows[moving.?].id;
        if (!drag_backdrop_valid or drag_backdrop_id != id) {
            const target = screen;
            screen = drag_backdrop.?;
            screen.resetClip();
            const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
            paintWallpaper(full);
            for (z_order[0..window_count]) |idx| {
                if (idx != moving.?) paintWindow(&windows[idx], false, full);
            }
            screen = target;
            drag_backdrop_valid = true;
            drag_backdrop_id = id;
        }
        // The moving title still samples its real, current backdrop; the
        // complete window and shell are rendered normally above this cache.
        var y = clip.y * screen.scale;
        while (y < clip.bottom() * screen.scale) : (y += 1) {
            const start: usize = @intCast(y * screen.stride + clip.x * screen.scale);
            const len: usize = @intCast(clip.w * screen.scale);
            @memcpy(screen.pixels[start..][0..len], drag_backdrop.?.pixels[start..][0..len]);
        }
        paintWindow(&windows[moving.?], true, clip);
    } else {
        drag_backdrop_valid = false;
        paintWallpaper(clip);
        for (z_order[0..window_count]) |idx| paintWindow(&windows[idx], activeWindow() == idx, clip);
    }

    syncShell();
    desktop.paint(&screen, &shell);
}

/// Publish an already-composited rectangle to the visible framebuffer.
fn present(area: Rect) void {
    const clip = Rect.intersect(area, .{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
    if (clip.isEmpty()) return;

    var y = clip.y * screen.scale;
    while (y < clip.bottom() * screen.scale) : (y += 1) {
        const src_row: usize = @intCast(y * screen.stride);
        const dst_row: usize = @intCast(y * front.stride);
        const x: usize = @intCast(clip.x * screen.scale);
        const width: usize = @intCast(clip.w * screen.scale);
        @memcpy(front.pixels[dst_row + x ..][0..width], screen.pixels[src_row + x ..][0..width]);
    }
}

// ── Input ───────────────────────────────────────────────────────────────────

var server_port: i64 = -1;

// ── Client protocol ─────────────────────────────────────────────────────────

const ACCENTS = [_]Color{ ORANGE, 0x60A0E0, 0x70C070, 0xD070C0, 0xE0B040 };

fn sendCreated(reply: i64, id: u32, width: u32, height: u32) void {
    const created = proto.Created{ .window_id = id, .width = width, .height = height };
    const bytes: [*]const u8 = @ptrCast(&created);
    _ = pulp.portSend(reply, proto.Op.created, bytes[0..@sizeOf(proto.Created)]) catch {};
}

fn handleCreateWindow(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.CreateWindow)) return;
    const req: *align(1) const proto.CreateWindow = @ptrCast(payload.ptr);

    // Connect before doing fallible work so a rejected request receives an
    // answer instead of leaving the client blocked forever.
    var reply_name_buf: [32]u8 = undefined;
    const reply_name = proto.replyPortName(&reply_name_buf, req.pid);
    const reply = pulp.portConnect(reply_name) catch {
        pulp.puts("peel: client has no reply port\n");
        return;
    };

    if (req.width == 0 or req.height == 0 or req.width > 2000 or req.height > 2000 or req.scale != @as(u32, @intCast(screen.scale))) {
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(reply);
        return;
    }
    const w: i32 = @intCast(req.width);
    const h: i32 = @intCast(req.height);

    const title_len = @min(req.title_len, 48);
    const name_len = @min(req.shm_name_len, 32);

    // Map the client's buffer. Peel takes it read-only in spirit: it copies
    // out of it and never writes back, so a misbehaving client can corrupt
    // its own window and nothing else.
    const shm = pulp.shmOpen(req.shm_name[0..name_len]) catch {
        pulp.puts("peel: client buffer not found\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(reply);
        return;
    };
    const pixels = pulp.shmMap(shm, false) catch {
        pulp.puts("peel: cannot map client buffer\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(shm);
        pulp.handleClose(reply);
        return;
    };

    const frame_w = w + BORDER_W * 2;
    const frame_h = h + TITLE_H + BORDER_W;
    const idx = addWindow(
        .{ .x = @max(0, @min(req.x, screen.width - frame_w)), .y = @max(desktop.BAR_H + 10, @min(req.y, screen.height - desktop.DOCK_H - 30 - frame_h)), .w = frame_w, .h = frame_h },
        req.title[0..title_len],
        ACCENTS[window_count % ACCENTS.len],
    ) orelse {
        pulp.puts("peel: window limit reached\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(shm);
        pulp.handleClose(reply);
        return;
    };

    windows[idx].pixels = @ptrCast(@alignCast(pixels));
    windows[idx].client_w = w;
    windows[idx].client_h = h;
    windows[idx].reply_port = reply;
    windows[idx].buffer_handle = shm;
    windows[idx].owner_pid = req.pid;
    windows[idx].closable = req.flags & proto.WindowFlags.closable != 0;
    pending_apps[appIndex(windows[idx].title())] = -1;

    // A shared reply port would deliver one client's answer to whichever
    // client happened to read first, so each process owns its own port.
    sendCreated(reply, windows[idx].id, req.width, req.height);

    pulp.print("peel: window {d} \"{s}\" {d}x{d} for pid {d}\n", .{
        windows[idx].id, windows[idx].title(), w, h, req.pid,
    });

    addDamage(windows[idx].damageRect());
}

fn removeWindow(index: usize) void {
    if (index >= window_count) return;

    const removed = windows[index];
    if (pointer_capture == removed.id) pointer_capture = null;
    if (hover_window == removed.id) hover_window = null;
    if (dragging == removed.id) dragging = null;
    addDamage(removed.damageRect());
    if (removed.reply_port >= 0) pulp.handleClose(removed.reply_port);
    if (removed.buffer_handle >= 0) pulp.handleClose(removed.buffer_handle);

    var order_pos: usize = 0;
    while (order_pos < window_count and z_order[order_pos] != index) : (order_pos += 1) {}
    var j = order_pos;
    while (j + 1 < window_count) : (j += 1) z_order[j] = z_order[j + 1];

    var i = index;
    while (i + 1 < window_count) : (i += 1) windows[i] = windows[i + 1];

    window_count -= 1;
    i = 0;
    while (i < window_count) : (i += 1) {
        if (z_order[i] > index) z_order[i] -= 1;
    }

    // The newly exposed top window changes from inactive to active.
    if (activeWindow()) |idx| addDamage(windows[idx].damageRect());
    chromeDamage();
    pulp.print("peel: closed window {d} \"{s}\" for pid {d}\n", .{
        removed.id, removed.title(), removed.owner_pid,
    });
}

fn handleDestroy(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.Destroy)) return;
    const d: *align(1) const proto.Destroy = @ptrCast(payload.ptr);
    const idx = findWindowById(d.window_id) orelse return;
    removeWindow(idx);
}

fn handleCommit(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.Commit)) return;
    const c: *align(1) const proto.Commit = @ptrCast(payload.ptr);

    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (windows[i].id != c.window_id) continue;
        windows[i].revision +%= 1;
        if (shell.popup == .overview) {
            // Workspace-switcher semantics: hold the backdrop while live
            // previews update. On dismissal shellAction repaints the whole
            // desktop from current client buffers. A clock tick must not
            // trigger a full blurred multi-window reconstruction every second.
            overview_damage.add(desktop.windowCard(&screen, i));
            return;
        }
        if (!windows[i].visible) return;
        if (windows[i].zoomed) {
            addDamage(windows[i].contentRect());
            return;
        }
        const content = windows[i].contentRect();
        // Client coordinates are relative to its own buffer; translate into
        // screen space before damaging.
        addDamage(.{
            .x = content.x + c.x,
            .y = content.y + c.y,
            .w = c.w,
            .h = c.h,
        });
        return;
    }
}

fn pumpClients() void {
    if (server_port < 0) return;

    var buf: [1024]u8 = undefined;
    // Bound each batch: a busy client must not keep the compositor in message
    // handling forever. waitInput observes remaining port messages immediately.
    var handled: usize = 0;
    while (handled < 32) : (handled += 1) {
        const m = pulp.portRecvMsg(server_port, &buf, false) catch return;
        if (m.len == 0) return;
        drag_backdrop_valid = false;
        switch (m.opcode) {
            proto.Op.display_info => {
                if (m.len != 8) continue;
                const pid = @as(*align(1) const i64, @ptrCast(&buf)).*;
                var name_buf: [32]u8 = undefined;
                const reply = pulp.portConnect(proto.replyPortName(&name_buf, pid)) catch continue;
                const scale: u32 = @intCast(screen.scale);
                _ = pulp.portSend(reply, proto.Op.display_info_reply, @import("std").mem.asBytes(&scale)) catch {};
                pulp.handleClose(reply);
            },
            proto.Op.create_window => handleCreateWindow(buf[0..m.len]),
            proto.Op.commit => handleCommit(buf[0..m.len]),
            proto.Op.destroy => handleDestroy(buf[0..m.len]),
            proto.Op.launch_app => {
                if (m.len >= 4) {
                    const app: *align(1) const u32 = @ptrCast(&buf);
                    if (app.* < 6) {
                        launchApp(@intCast(app.*), false);
                        chromeDamage();
                    }
                }
            },
            proto.Op.desktop_panel => {
                if (m.len == 4) {
                    const action = @as(*align(1) const u32, @ptrCast(&buf)).*;
                    if (action == desktop.Action.settings or action == desktop.Action.overview) {
                        shellAction(@intCast(action));
                        pulp.print("desktop: requested panel {d}\n", .{action});
                    }
                }
            },
            else => {},
        }
    }
}

var dragging: ?u32 = null;
var pointer_capture: ?u32 = null;
var hover_window: ?u32 = null;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var buttons: u8 = 0;
var frames: u64 = 0;

/// Send an input event to a window's client, in coordinates relative to its
/// own buffer. A client should never need to know where on screen it sits.
fn sendInput(idx: usize, kind: u8, code: u8, value: u8, sx: i32, sy: i32) void {
    const w = &windows[idx];
    if (w.reply_port < 0) return;

    const content = w.contentRect();
    const msg = proto.Input{
        .window_id = w.id,
        .kind = kind,
        .code = code,
        .value = value,
        .reserved = 0,
        .x = @divFloor((sx - content.x) * w.client_w, @max(1, content.w)),
        .y = @divFloor((sy - content.y) * w.client_h, @max(1, content.h)),
    };
    const bytes: [*]const u8 = @ptrCast(&msg);
    _ = pulp.portSend(w.reply_port, proto.Op.input, bytes[0..@sizeOf(proto.Input)]) catch {};
}

fn sendInputById(id: u32, kind: u8, code: u8, value: u8, sx: i32, sy: i32) void {
    const idx = findWindowById(id) orelse return;
    sendInput(idx, kind, code, value, sx, sy);
}

fn requestClose(id: u32) void {
    const idx = findWindowById(id) orelse return;
    const msg = proto.Destroy{ .window_id = id };
    const bytes: [*]const u8 = @ptrCast(&msg);
    if (windows[idx].reply_port >= 0) {
        _ = pulp.portSend(
            windows[idx].reply_port,
            proto.Op.close_requested,
            bytes[0..@sizeOf(proto.Destroy)],
        ) catch {};
    }
    // Remove immediately, so a slow or crashed client cannot leave a dead
    // frame on the desktop. A later destroy message is harmlessly ignored.
    removeWindow(idx);
}

fn handleMouse(e: *const pulp.InputEvent) void {
    prev_cursor_x = cursor_x;
    prev_cursor_y = cursor_y;

    var motion = pointer.Motion{ .x = cursor_x, .y = cursor_y };
    motion.move(e.dx, e.dy, screen.width, screen.height);
    cursor_x = motion.x;
    cursor_y = motion.y;

    const was_down = buttons & 1 != 0;
    const is_down = e.code & 1 != 0;
    buttons = e.code;

    cursor_dirty = cursor_dirty or prev_cursor_x != cursor_x or prev_cursor_y != cursor_y;
    if (shell.popup == .none) if (windowAt(prev_cursor_x, prev_cursor_y)) |idx| {
        for (0..3) |i| {
            const c = windows[idx].control(@intCast(i));
            if (c.contains(prev_cursor_x, prev_cursor_y) and !c.contains(cursor_x, cursor_y)) addDamage(c);
        }
    };
    if (shell.popup == .none) if (windowAt(cursor_x, cursor_y)) |idx| {
        for (0..3) |i| {
            const c = windows[idx].control(@intCast(i));
            if (c.contains(cursor_x, cursor_y) and !c.contains(prev_cursor_x, prev_cursor_y)) addDamage(c);
        }
    };
    syncShell();
    const hit = desktop.hit(&screen, &shell, cursor_x, cursor_y);
    if (hit != shell.hover) {
        addDamage(desktop.hoverDamage(&screen, &shell, shell.hover, hit));
        if (shell.popup == .overview) {
            for ([_]u16{ shell.hover, hit }) |action| {
                if (action >= desktop.Action.window and action < desktop.Action.window + shell.count)
                    overview_damage.add(desktop.windowCard(&screen, action - desktop.Action.window));
            }
        }
        shell.hover = hit;
    }

    // Desktop chrome captures a complete press/release pair, including a
    // release outside the target. Never leak that release into a client.
    if (dragging == null and control_pressed == null and pointer_capture == null and (hit != 0 or shell_pressed != null)) {
        if (hover_window) |old| sendInputById(old, pulp.EV_MOUSE, 0, 0, -10000, -10000);
        hover_window = null;
        if (is_down and !was_down) shell_pressed = hit;
        if (!is_down and was_down) {
            if (shell_pressed) |pressed| if (pressed == hit) {
                shellAction(hit);
            };
            shell_pressed = null;
        }
        return;
    }

    if (is_down and !was_down) {
        if (windowAt(cursor_x, cursor_y)) |idx| {
            focusWindow(idx);
            const id = windows[idx].id;
            if (windows[idx].titleBar().contains(cursor_x, cursor_y)) {
                var control: i32 = 0;
                while (control < 3) : (control += 1) {
                    if (control == 0 and !windows[idx].closable) continue;
                    if (windows[idx].control(control).contains(cursor_x, cursor_y)) {
                        control_pressed = .{ .id = id, .control = control };
                        break;
                    }
                }
                if (control_pressed == null and !windows[idx].zoomed) {
                    dragging = id;
                    drag_backdrop_valid = false;
                    drag_dx = cursor_x - windows[idx].rect.x;
                    drag_dy = cursor_y - windows[idx].rect.y;
                }
            } else {
                pointer_capture = id;
            }
        }
    }

    if (dragging) |id| if (is_down) {
        const idx = findWindowById(id) orelse {
            dragging = null;
            return;
        };
        // Damage both where the window was and where it is going, or the old
        // position is left painted on screen.
        addDamage(windows[idx].damageRect());
        const min_x = -windows[idx].rect.w + 40;
        const max_x = screen.width - 40;
        windows[idx].rect.x = @max(min_x, @min(cursor_x - drag_dx, max_x));
        windows[idx].rect.y = @max(desktop.BAR_H, @min(cursor_y - drag_dy, screen.height - desktop.DOCK_H - TITLE_H - 22));
        addDamage(windows[idx].damageRect());
    };

    if (!is_down and was_down) {
        if (control_pressed) |pressed| {
            if (findWindowById(pressed.id)) |idx| {
                if (windows[idx].control(pressed.control).contains(cursor_x, cursor_y)) {
                    switch (pressed.control) {
                        0 => requestClose(pressed.id),
                        1 => {
                            windows[idx].visible = false;
                            addDamage(windows[idx].damageRect());
                            if (activeWindow()) |active| addDamage(windows[active].damageRect());
                            chromeDamage();
                            pulp.print("desktop: minimized window {d}\n", .{pressed.id});
                        },
                        2 => zoomWindow(idx),
                        else => {},
                    }
                }
            }
            control_pressed = null;
            return;
        }
        dragging = null;
    }

    if (dragging == null and control_pressed == null) {
        var target = pointer_capture;
        if (target == null) {
            if (clientWindowAt(cursor_x, cursor_y)) |idx| target = windows[idx].id;
        }

        if (hover_window) |old| {
            if (target == null or target.? != old) {
                // An out-of-bounds event clears hover/pressed state in the old
                // client instead of leaving a button visually stuck.
                sendInputById(old, pulp.EV_MOUSE, buttons, 0, cursor_x, cursor_y);
            }
        }
        if (target) |id| sendInputById(id, pulp.EV_MOUSE, buttons, 0, cursor_x, cursor_y);
        hover_window = target;

        // The pressed client receives the release even after a drag outside;
        // following movement is routed by ordinary hit testing again.
        if (!is_down) pointer_capture = null;
    } else if (hover_window) |old| {
        sendInputById(old, pulp.EV_MOUSE, buttons, 0, cursor_x, cursor_y);
        hover_window = null;
    }
}

fn handleKey(e: *const pulp.InputEvent) void {
    drag_backdrop_valid = false;
    if (e.isPress() and e.code == 0x01 and shell.popup != .none) {
        shellAction(desktop.Action.dismiss);
        return;
    }
    // F3: window overview. F4: appearance. F11: reveal the desktop.
    if (e.isPress()) switch (e.code) {
        0x3D => {
            shellAction(desktop.Action.overview);
            return;
        },
        0x3E => {
            shellAction(desktop.Action.settings);
            return;
        },
        0x57 => {
            shellAction(desktop.Action.desktop);
            return;
        },
        else => {},
    };
    if (shell.popup != .none) return;
    // Tab cycles focus, so the compositor is demonstrable without a mouse.
    if (e.isPress() and e.code == 0x0F and window_count > 1) {
        for (0..window_count) |i| {
            const idx = z_order[i];
            if (windows[idx].visible) {
                focusWindow(idx);
                break;
            }
        }
        return;
    }

    // Everything else goes to the focused window - the top of the z-order.
    // Peel does not interpret keys; it routes them.
    if (activeWindow()) |idx| sendInput(idx, e.kind, e.code, e.value, 0, 0);
}

// ── Entry ───────────────────────────────────────────────────────────────────

export fn _start() callconv(.c) noreturn {
    const info = pulp.fbAcquire() catch {
        pulp.puts("peel: cannot acquire the framebuffer\n");
        pulp.exit(1);
    };

    const framebuffer_pixels = pulp.fbMap() catch {
        pulp.puts("peel: cannot map the framebuffer\n");
        pulp.exit(1);
    };

    const display_scale: i32 = if (info.width >= 2560 and info.height >= 1600) 2 else 1;
    front = .{
        .pixels = framebuffer_pixels,
        .width = @divTrunc(@as(i32, @intCast(info.width)), display_scale),
        .height = @divTrunc(@as(i32, @intCast(info.height)), display_scale),
        .scale = display_scale,
        .stride = @intCast(info.pitch / 4),
    };

    const back_bytes = @as(usize, info.width) * @as(usize, info.height) * @sizeOf(u32);
    back_handle = pulp.shmCreate("", back_bytes) catch {
        pulp.puts("peel: cannot allocate back buffer\n");
        pulp.exit(1);
    };
    const back_pixels = pulp.shmMap(back_handle, true) catch {
        pulp.puts("peel: cannot map back buffer\n");
        pulp.exit(1);
    };
    screen = .{
        .pixels = @ptrCast(@alignCast(back_pixels)),
        .width = front.width,
        .height = front.height,
        .stride = front.width * display_scale,
        .scale = display_scale,
    };
    pulp.print("peel: {d}x{d}, {d} bpp, stride {d}, double-buffered\n", .{
        info.width, info.height, info.bpp, front.stride,
    });

    cursor_x = @divTrunc(screen.width, 2);
    cursor_y = @divTrunc(screen.height, 2);
    prev_cursor_x = cursor_x;
    prev_cursor_y = cursor_y;

    server_port = pulp.portCreate(proto.PORT) catch {
        pulp.puts("peel: cannot create the client port\n");
        pulp.exit(1);
    };
    pulp.print("peel: serving clients on port \"{s}\"\n", .{proto.PORT});

    // Register the client port as the compositor's wake source, so a client
    // message and an input event arrive on the same channel and the main loop
    // has exactly one thing to wait on.
    pulp.inputBind(server_port);

    // Publish the port before building the wallpaper: Seed starts apps in
    // parallel and they must be able to queue their window requests now.
    // Allocation failure simply uses the procedural fallback.
    if (pulp.shmCreate("", back_bytes)) |h| {
        if (pulp.shmMap(h, true)) |pixels| {
            wallpaper = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = screen.width, .height = screen.height, .stride = screen.stride, .scale = screen.scale };
            rebuildWallpaper();
        } else |_| {}
    } else |_| {}

    // Optional, one-time storage; allocation failure preserves normal drawing.
    if (pulp.shmCreate("", back_bytes)) |h| {
        if (pulp.shmMap(h, true)) |pixels| {
            drag_backdrop = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = screen.width, .height = screen.height, .stride = screen.stride, .scale = screen.scale };
        } else |_| {
            pulp.handleClose(h);
        }
    } else |_| {}

    // First frame: everything.
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    composite(full);
    present(full);
    drawCursor(&front, cursor_x, cursor_y);
    presented_cursor_x = cursor_x;
    presented_cursor_y = cursor_y;
    clearDamage();

    var events: [64]pulp.InputEvent = undefined;
    while (true) {
        const seconds = pulp.wallTime();
        if (seconds != shell.seconds) {
            if (shell.seconds == null and seconds != null) pulp.print("desktop: wall clock UTC {d}, offset {d} minutes\n", .{ seconds.?, pulp.timezone_minutes });
            shell.seconds = seconds;
            addDamage(.{ .x = screen.width - 330, .y = 0, .w = 330, .h = desktop.BAR_H });
        }

        const n = pulp.inputRead(&events);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = &events[i];
            switch (e.kind) {
                pulp.EV_MOUSE => handleMouse(e),
                pulp.EV_KEY => handleKey(e),
                else => {},
            }
        }

        // A long scene frame must not delay this batch's pointer until after
        // blur, window copying or further client message handling.
        if (cursor_dirty) {
            present(cursorRect(presented_cursor_x, presented_cursor_y));
            present(cursorRect(cursor_x, cursor_y));
            drawCursor(&front, cursor_x, cursor_y);
            presented_cursor_x = cursor_x;
            presented_cursor_y = cursor_y;
            if (pulp.desktop_profile) pulp.print("perf: pointer {d},{d}\n", .{ cursor_x, cursor_y });
        }
        pumpClients();

        // If a base is unavailable (e.g. unusual display bounds), use the
        // ordinary full-glass path. Never restore an uninitialized snapshot.
        if (overview_damage.count != 0 and shell.popup == .overview and !desktop.overviewValid()) addDamage(desktop.popupRect(&screen, .overview));

        if (damage.count != 0 or overview_damage.count != 0 or cursor_dirty) {
            const started = if (pulp.desktop_profile) pulp.uptimeMs() else 0;
            var repainted_area: i32 = 0;
            if (damage.count != 0) {
                // Expand/merge glass dependencies to a fixed point BEFORE
                // drawing. Overlapping regions are then rendered only once.
                var resolved = damage;
                while (true) {
                    var next: gfx.Damage = .{};
                    var grew = false;
                    for (resolved.rects[0..resolved.count]) |r| {
                        const expanded = expandedDamage(r);
                        grew = grew or expanded.x != r.x or expanded.y != r.y or expanded.w != r.w or expanded.h != r.h;
                        next.add(expanded);
                    }
                    const stable = !grew and next.count == resolved.count;
                    resolved = next;
                    if (stable) break;
                }
                for (resolved.rects[0..resolved.count]) |r| {
                    composite(r);
                    repainted_area += r.w * r.h;
                }
                // Publish only after all scene rectangles are complete.
                for (resolved.rects[0..resolved.count]) |r| present(r);
            }
            if (shell.popup == .overview) {
                syncShell();
                for (overview_damage.rects[0..overview_damage.count]) |r| {
                    screen.setClip(r);
                    if (desktop.paintOverviewUpdate(&screen, &shell)) {
                        present(r);
                        repainted_area += r.w * r.h;
                    }
                }
                screen.resetClip();
            }
            present(cursorRect(presented_cursor_x, presented_cursor_y));
            present(cursorRect(cursor_x, cursor_y));
            drawCursor(&front, cursor_x, cursor_y);
            presented_cursor_x = cursor_x;
            presented_cursor_y = cursor_y;
            cursor_dirty = false;
            if (pulp.desktop_profile) pulp.print("perf: frame {d}ms area {d} cursor {d},{d}\n", .{ pulp.uptimeMs() - started, repainted_area, cursor_x, cursor_y });
            clearDamage();
            frames += 1;
        }

        // Sleep until either source has work. input_wait registers before it
        // checks both the input queue and this process's bound client port, so
        // an event landing between this loop and the syscall cannot be lost.
        // Civil time updates once per second; scheduling stays monotonic.
        pulp.waitInput(1000 - pulp.uptimeMs() % 1000);
    }
}
