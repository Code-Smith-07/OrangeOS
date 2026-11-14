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
const window_body = @import("window_body.zig");
const frame = @import("frame.zig");
const menus = desktop.menus;
const notes_mod = desktop.notes;
const account_mod = @import("account");
const std = @import("std");
const host_model = @import("host_model");
var host_json: [4096]u8 = undefined;
var host_scratch: [32768]u8 = undefined;

const Rect = gfx.Rect;
const Color = gfx.Color;

// ── Theme ───────────────────────────────────────────────────────────────────

const ORANGE: Color = 0xFF8C1A;

// The measured macOS title bar (docs/design/014); see frame.zig.
const TITLE_H: i32 = frame.TITLE_H;
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
    /// Title bar, or full-size content with the buttons in the client's bar.
    style: frame.Style = .{},
    /// Resizable windows (docs/design/014, M2): the size limits, the frame
    /// the user asked for, and the configure Peel is waiting on. The frame
    /// changes only once the client has drawn the new size, so a window is
    /// never shown stretched or half drawn.
    resizable: bool = false,
    min_w: i32 = 0,
    min_h: i32 = 0,
    cap_w: i32 = 0,
    cap_h: i32 = 0,
    want: ?Rect = null,
    want_edges: frame.Edges = .{},
    configure_sent: ?[2]i32 = null,
    configure_at: u64 = 0,
    /// Which application the window belongs to (proto.App.*).
    app: u32 = 0,
    /// The app's menus as it sent them (parsed when it is in front).
    menu_buf: [proto.MENU_MAX_BYTES]u8 = undefined,
    menu_len: usize = 0,
    menu_serial: u32 = 0,
    /// The close button asks the client first; when it was last asked, and
    /// when the client last sent anything (to tell busy from stuck).
    confirms_close: bool = false,
    close_asked_ms: u64 = 0,
    last_msg_ms: u64 = 0,
    /// Tiled to half the screen (restore_rect keeps the size from before).
    tiled: frame.Tile = .none,
    /// Open, minimise and restore motion: the frame drawn, from and to, and
    /// the opacity range.
    anim: ?Anim = null,

    /// A client-backed window owns a shared buffer the client renders into.
    /// Peel only ever reads it. A window with no buffer is drawn by Peel
    /// itself, which is how the boot placeholder works before any client
    /// has connected.
    pixels: ?[*]const u32 = null,
    client_w: i32 = 0,
    client_h: i32 = 0,
    /// Buffer pixels per row: capacity_w * scale for resizable windows.
    stride: i32 = 0,
    reply_port: i64 = -1,
    buffer_handle: i64 = -1,
    owner_pid: i64 = -1,
    closable: bool = true,
    panel: bool = false,
    id: u32 = 0,
    revision: u64 = 0,
    /// Input the client's port had no room for (its queue holds 16), sent
    /// in order before anything newer: a lost key or button release would
    /// leave it held in the client (a stuck Ctrl turns typing into
    /// shortcuts). Only pure pointer motion may be dropped.
    backlog: [32]proto.Input = undefined,
    backlog_len: usize = 0,
    /// The button mask last sent or queued, to tell motion from clicks.
    sent_buttons: u8 = 0,

    fn title(self: *const Window) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn setTitle(self: *Window, t: []const u8) void {
        self.title_len = @min(t.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], t[0..self.title_len]);
    }

    /// Where the client's content sits inside the frame.
    fn contentRect(self: *const Window) Rect {
        if (self.panel) return self.rect;
        return self.style.content(self.rect);
    }

    /// Peel's own title bar; for full-size content, the client's top bar,
    /// which only Peel's window buttons share.
    fn titleBar(self: *const Window) Rect {
        if (self.panel) return .{ .x = self.rect.x, .y = self.rect.y, .w = 0, .h = 0 };
        return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w, .h = if (self.style.full_size) 0 else TITLE_H };
    }

    fn control(self: *const Window, index: i32) Rect {
        return self.style.button(self.rect, index);
    }

    /// Fixed-size windows can still zoom by scaling (the older behaviour).
    fn zoomable(self: *const Window) bool {
        return !self.panel;
    }

    fn limits(self: *const Window) frame.Limits {
        const min = self.style.frameSize(self.min_w, self.min_h);
        const max = self.style.frameSize(self.cap_w, self.cap_h);
        return .{ .min_w = min[0], .min_h = min[1], .max_w = max[0], .max_h = max[1] };
    }

    /// The area the compositor must repaint for this window: its frame plus
    /// the shadow that falls outside it (and, while it moves, its path).
    fn damageRect(self: *const Window) Rect {
        const r = Rect{
            .x = self.rect.x - SHADOW,
            .y = self.rect.y - SHADOW,
            .w = self.rect.w + SHADOW * 2,
            .h = self.rect.h + SHADOW * 2 + 8,
        };
        const a = self.anim orelse return r;
        var u = r;
        for ([_]Rect{ a.from, a.to }) |m| u = Rect.unionWith(u, .{ .x = m.x - SHADOW, .y = m.y - SHADOW, .w = m.w + SHADOW * 2, .h = m.h + SHADOW * 2 + 8 });
        return u;
    }
};

const Anim = struct {
    from: Rect,
    to: Rect,
    alpha_from: u8,
    alpha_to: u8,
    start: u64,
    /// Hide the window when the motion ends (minimise).
    hide: bool = false,

    fn progress(self: Anim, now: u64) i32 {
        return frame.easeOut(@intCast(@min(1000, (now -| self.start) * 1000 / frame.MOTION_MS)));
    }
    fn rect(self: Anim, now: u64) Rect {
        return frame.lerpRect(self.from, self.to, self.progress(now));
    }
    fn alpha(self: Anim, now: u64) u8 {
        const t = self.progress(now);
        return @intCast(@as(i32, self.alpha_from) + @divTrunc((@as(i32, self.alpha_to) - self.alpha_from) * t, 1000));
    }
    fn done(self: Anim, now: u64) bool {
        return now -| self.start >= frame.MOTION_MS;
    }
};

/// Reduce Motion (Appearance): no open or minimise motion.
var reduce_motion = false;
/// One clock reading per frame, so every damaged rectangle of a moving
/// window is drawn at the same point of its motion.
var frame_now: u64 = 0;

fn startAnim(idx: usize, from: Rect, to: Rect, alpha_from: u8, alpha_to: u8, hide: bool) void {
    const w = &windows[idx];
    if (reduce_motion or anim_scratch == null) {
        if (hide) w.visible = false;
        return;
    }
    addDamage(w.damageRect());
    w.anim = .{ .from = from, .to = to, .alpha_from = alpha_from, .alpha_to = alpha_to, .start = pulp.uptimeMs(), .hide = hide };
    addDamage(w.damageRect());
}

/// Advance every moving window; true while any is still moving.
fn tickAnimations() bool {
    var moving = false;
    for (windows[0..window_count]) |*w| {
        const a = w.anim orelse continue;
        addDamage(w.damageRect());
        if (!a.done(frame_now)) {
            moving = true;
            continue;
        }
        w.anim = null;
        if (a.hide) {
            w.visible = false;
            if (activeWindow()) |active| addDamage(windows[active].damageRect());
            chromeDamage();
        }
        if (pulp.desktop_profile) pulp.print("desktop: motion done {d}\n", .{w.id});
    }
    return moving;
}

/// The dock tile an application's window minimises into.
fn dockTileFor(w: *const Window) Rect {
    return desktop.dockItem(&screen, desktop.dockSlot(w.app));
}
/// The work area: below the menu bar, down to the bottom of the screen
/// (windows may sit behind the dock, as on the Mac).
fn workArea() Rect {
    return .{ .x = 0, .y = desktop.BAR_H, .w = screen.width, .h = screen.height - desktop.BAR_H - desktop.DOCK_H - 14 };
}

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
    if (windows[index].visible and activeWindow() == index) return;
    if (activeWindow()) |previous| addDamage(windows[previous].damageRect());
    // Coming back from the dock: rise out of its tile.
    const minimized = !windows[index].visible and !windows[index].panel and desktop_hidden_count == 0;
    if (windows[index].anim) |a| if (a.hide) {
        windows[index].anim = null; // restored while still minimising
    };
    windows[index].visible = true;
    if (minimized) startAnim(index, dockTileFor(&windows[index]), windows[index].rect, 0, 255, false);
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
const spotlight = desktop.spotlight;
const keymap = @import("keymap");
var wallpapers: [desktop.THEME_NAMES.len]?gfx.Surface = [_]?gfx.Surface{null} ** desktop.THEME_NAMES.len;
const WALLPAPER_PATHS = [_][]const u8{
    "/share/wallpapers/coastal-glass.bmp",
    "/share/wallpapers/citrus-atelier.bmp",
    "/share/wallpapers/midnight-aurora.bmp",
};
var pending_apps: [desktop.APP_COUNT]i64 = [_]i64{-1} ** desktop.APP_COUNT;
/// A document waiting for the app Peel started for it: handed over when
/// that process creates its window.
const PendingOpen = struct { pid: i64 = -1, len: usize = 0, path: [256]u8 = undefined };
var pending_open: [4]PendingOpen = [_]PendingOpen{.{}} ** 4;
/// The front app's menus, parsed from a private copy of its text.
var bar_text: [proto.MENU_MAX_BYTES]u8 = undefined;
var bar: menus.Bar = .{};
var bar_key: u64 = ~@as(u64, 0);
var note_store: notes_mod.Store = .{};
var banner_shown = false;
var battery_warned = false;
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
    if (@import("std").mem.eql(u8, title, "Control Center")) return 6;
    if (@import("std").mem.eql(u8, title, "Files")) return 4;
    if (@import("std").mem.eql(u8, title, "Trash")) return 5;
    if (@import("std").mem.eql(u8, title, "Orange Browser")) return 7;
    if (title.len >= 7 and @import("std").mem.eql(u8, title[0..7], "Squeeze")) return 1;
    if (@import("std").mem.eql(u8, title, "clock")) return 2;
    if (title.len >= 5 and @import("std").mem.eql(u8, title[0..5], "About")) return 3;
    return 0;
}

fn syncShell() void {
    shell.active = "Desktop";
    shell.app_name = "Desktop";
    var top_win: ?*const Window = null;
    var z = window_count;
    while (z > 0) {
        z -= 1;
        const w = &windows[z_order[z]];
        if (w.visible and !w.panel) {
            shell.active = w.title();
            shell.app_name = desktop.APP_NAMES[w.app];
            top_win = w;
            break;
        }
    }
    // The menu bar: the top_win app's menus, then Peel's Window menu. Parsed
    // again only when the top_win window or its menus change.
    const key: u64 = if (top_win) |w| (@as(u64, w.id) << 32) | (@as(u64, w.menu_serial) << 1) | @intFromBool(w.resizable) else 0;
    if (key != bar_key) {
        bar_key = key;
        const len = if (top_win) |w| w.menu_len else 0;
        if (top_win) |w| @memcpy(bar_text[0..len], w.menu_buf[0..len]);
        bar = menus.parse(bar_text[0..len]);
        bar.menus[bar.count] = menus.windowMenu(top_win != null, if (top_win) |w| w.resizable else false);
        bar.count += 1;
        if (shell.popup == .app_menu) shell.popup = .none;
        addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
    }
    shell.bar = &bar;
    shell.notes = &note_store;
    shell.banner = if (lock.active) null else note_store.banner(pulp.uptimeMs());
    shell.running = [_]bool{false} ** desktop.APP_COUNT;
    shell.count = 0;
    shell.controls_open = false;
    shell.reduce_motion = reduce_motion;
    for (0..window_count) |i| {
        if (windows[i].panel) {
            shell.controls_open = shell.controls_open or windows[i].visible;
            continue;
        }
        const app: usize = windows[i].app;
        shell.running[app] = true;
        shell.items[shell.count] = .{ .id = windows[i].id, .revision = windows[i].revision, .title = windows[i].title(), .hidden = !windows[i].visible, .app = app, .pixels = windows[i].pixels, .width = windows[i].client_w * screen.scale, .height = windows[i].client_h * screen.scale, .stride = windows[i].stride };
        shell.count += 1;
    }
}

fn openPanel() ?usize {
    for (0..window_count) |i| if (windows[i].panel and windows[i].visible) return i;
    return null;
}

fn dismissPanel() void {
    const idx = openPanel() orelse return;
    // Cancel an unfinished slider gesture without submitting a host request.
    sendInput(idx, pulp.EV_MOUSE, 0, 0, -10000, -10000);
    pointer_capture = null;
    hover_window = null;
    windows[idx].visible = false;
    addDamage(windows[idx].damageRect());
    if (activeWindow()) |active| addDamage(windows[active].damageRect());
    chromeDamage();
    pulp.puts("desktop: control panel dismissed\n");
}

fn sendAppearance(idx: usize) void {
    const palette: u32 = @intCast(shell.palette);
    _ = pulp.portSend(windows[idx].reply_port, proto.Op.appearance, @import("std").mem.asBytes(&palette)) catch {};
}

fn launchApp(app: usize, new_instance: bool) void {
    if (!new_instance) {
        var i = window_count;
        while (i > 0) {
            i -= 1;
            const idx = z_order[i];
            if (windows[idx].app == app) {
                focusWindow(idx);
                if (windows[idx].panel) pulp.puts("desktop: control panel opened\n");
                return;
            }
        }
        if (pending_apps[app] > 0) {
            const ended = pulp.waitNoHang(pending_apps[app]) catch @as(?i64, 0);
            if (ended == null) return;
        }
    }
    _ = startApp(app);
}

const APP_PATHS = [desktop.APP_COUNT][]const u8{ "/bin/grove", "/bin/squeeze", "/bin/clock", "/bin/about", "/bin/files", "/bin/trash", "/bin/hardware", "/bin/orange-browser", "/bin/editor", "/bin/viewer", "/bin/calculator", "/bin/settings" };

/// Start an application's program; its pid, or null with a notice.
fn startApp(app: usize) ?i64 {
    if (window_count == MAX_WINDOWS) {
        shell.notice = "Window limit reached. Close a window.";
        return null;
    }
    const pid = pulp.spawn(APP_PATHS[app]) catch {
        shell.notice = "Could not start the application.";
        return null;
    };
    pending_apps[app] = pid;
    pulp.print("desktop: launched {s}\n", .{APP_PATHS[app]});
    return pid;
}

fn hasExtension(path: []const u8, comptime list: []const []const u8) bool {
    inline for (list) |ext| {
        if (path.len > ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Open a file or folder with the application that handles it, the way a
/// double click in Files or a Spotlight result does: folders in Files,
/// pictures in Image Viewer, everything else in Text Editor.
fn openDocument(path: []const u8) void {
    if (path.len == 0 or path.len > 255 or path[0] != '/') return;
    const st = pulp.stat(path) catch {
        shell.notice = "That item is no longer there.";
        return;
    };
    const app: usize = if (st.isDir()) proto.App.files else if (hasExtension(path, &.{ ".png", ".bmp", ".ppm" })) proto.App.viewer else proto.App.editor;
    pulp.print("desktop: open {s} with {s}\n", .{ path, desktop.APP_NAMES[app] });
    if (app == proto.App.files) {
        // One Files window: show the folder in it when it is already open.
        for (0..window_count) |i| if (windows[i].app == proto.App.files) {
            _ = pulp.portSend(windows[i].reply_port, proto.Op.open_file, path) catch {};
            focusWindow(i);
            return;
        };
    }
    const pid = startApp(app) orelse return;
    for (&pending_open) |*slot| {
        if (slot.pid >= 0 and pulp.uptimeMs() -| slot_started(slot) < 30_000) continue;
        slot.pid = pid;
        slot.len = path.len;
        @memcpy(slot.path[0..path.len], path);
        pending_started[@divExact(@intFromPtr(slot) - @intFromPtr(&pending_open), @sizeOf(PendingOpen))] = pulp.uptimeMs();
        return;
    }
    shell.notice = "Too many documents are opening. Try again.";
}
var pending_started: [4]u64 = [_]u64{0} ** 4;
fn slot_started(slot: *const PendingOpen) u64 {
    return pending_started[@divExact(@intFromPtr(slot) - @intFromPtr(&pending_open), @sizeOf(PendingOpen))];
}

/// Post a notification: kept in the list, shown as a banner for a moment.
fn postNote(title: []const u8, body: []const u8, app: u32) void {
    if (!note_store.post(title, body, app, pulp.wallTime() orelse 0, pulp.uptimeMs())) return;
    pulp.print("desktop: notification \"{s}\" from {s}\n", .{ note_store.items[0].title(), desktop.APP_NAMES[@min(app, desktop.APP_COUNT - 1)] });
    addDamage(gfx.shadowExtent(desktop.bannerRect(&screen)));
    addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
    if (shell.popup == .notifications) addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
}

/// One of the open menu's items was chosen: Peel's own Window items act
/// here; an app's item goes back to the app with its id.
fn menuChosen(j: usize) void {
    if (shell.open_menu >= bar.count) return;
    const m = &bar.menus[shell.open_menu];
    if (j >= m.count) return;
    const item = m.items[j];
    if (!item.enabled or item.separator) return;
    pulp.print("desktop: menu {s} > {s}\n", .{ m.title, item.label });
    const top_win = activeWindow();
    if (item.id < menus.SHELL_ID) {
        const idx = top_win orelse return;
        _ = pulp.portSend(windows[idx].reply_port, proto.Op.menu_action, std.mem.asBytes(&item.id)) catch {};
        return;
    }
    switch (item.id) {
        menus.Shell.overview => shellAction(desktop.Action.overview),
        menus.Shell.show_desktop => toggleDesktop(),
        menus.Shell.minimise => if (top_win) |idx| minimizeWindow(idx),
        menus.Shell.zoom => if (top_win) |idx| zoomWindow(idx),
        menus.Shell.tile_left => if (top_win) |idx| tileWindow(idx, .left),
        menus.Shell.tile_right => if (top_win) |idx| tileWindow(idx, .right),
        menus.Shell.close => if (top_win) |idx| requestClose(windows[idx].id),
        else => {},
    }
}

fn minimizeWindow(idx: usize) void {
    // Shrink into the app's dock tile and fade out.
    startAnim(idx, windows[idx].rect, dockTileFor(&windows[idx]), 255, 0, true);
    addDamage(windows[idx].damageRect());
    if (activeWindow()) |active| addDamage(windows[active].damageRect());
    chromeDamage();
    pulp.print("desktop: minimized window {d}\n", .{windows[idx].id});
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
    if (w.resizable) {
        // A real zoom: the client lays itself out at the new size.
        if (w.zoomed or w.tiled != .none) untileWindow(idx) else tileWindow(idx, .fill);
        pulp.print("desktop: zoom window {d} = {d}\n", .{ w.id, @intFromBool(w.zoomed) });
        return;
    }
    addDamage(w.damageRect());
    if (w.zoomed) {
        w.rect = w.restore_rect;
    } else {
        w.restore_rect = w.rect;
        w.rect = frame.tileRect(workArea(), .fill);
    }
    w.zoomed = !w.zoomed;
    addDamage(w.damageRect());
    pulp.print("desktop: zoom window {d} = {d}\n", .{ w.id, @intFromBool(w.zoomed) });
}

/// Fill the left or right half, or the whole work area (zoom).
fn tileWindow(idx: usize, tile: frame.Tile) void {
    const w = &windows[idx];
    if (!w.resizable or tile == .none) return;
    if (w.tiled == .none and !w.zoomed) w.restore_rect = w.rect;
    w.tiled = tile;
    w.zoomed = tile == .fill;
    requestSize(idx, frame.tileRect(workArea(), tile), .{});
    pulp.print("desktop: tiled window {d} {s}\n", .{ w.id, @tagName(tile) });
}

fn untileWindow(idx: usize) void {
    const w = &windows[idx];
    if (w.tiled == .none and !w.zoomed) return;
    w.tiled = .none;
    w.zoomed = false;
    requestSize(idx, w.restore_rect, .{});
    pulp.print("desktop: untiled window {d}\n", .{w.id});
}

/// A press on a title bar (or a full-size client's toolbar): the second
/// press of a double click zooms, anything else starts a move.
fn titlePress(idx: usize) void {
    titleClick(idx);
    if (last_title_ms == null) return; // that was a double click: zoomed
    if (windows[idx].zoomed and !windows[idx].resizable) return;
    dragging = windows[idx].id;
    drag_backdrop_valid = false;
    drag_restore = windows[idx].resizable and (windows[idx].tiled != .none or windows[idx].zoomed);
    drag_start_x = cursor_x;
    drag_start_y = cursor_y;
    drag_dx = cursor_x - windows[idx].rect.x;
    drag_dy = cursor_y - windows[idx].rect.y;
}

/// The window whose frame, or the grab band just outside it, is topmost
/// under the pointer, and the edges a press there would take.
fn edgeTarget(x: i32, y: i32) ?struct { idx: usize, edges: frame.Edges } {
    var i: usize = window_count;
    while (i > 0) {
        i -= 1;
        const idx = z_order[i];
        const w = &windows[idx];
        if (!w.visible) continue;
        const r = w.rect;
        const outer = Rect{ .x = r.x - frame.GRAB_OUT, .y = r.y - frame.GRAB_OUT, .w = r.w + frame.GRAB_OUT * 2, .h = r.h + frame.GRAB_OUT * 2 };
        if (!outer.contains(x, y)) continue;
        if (!w.resizable or w.panel) return null;
        // The window buttons always win over the top-left corner.
        if (w.style.buttonGroup(r).contains(x, y)) return null;
        const e = frame.edgeAt(r, x, y);
        if (!e.any()) return null;
        return .{ .idx = idx, .edges = e };
    }
    return null;
}

fn shapeFor(e: frame.Edges) CursorShape {
    if ((e.left and e.top) or (e.right and e.bottom)) return .nwse;
    if ((e.right and e.top) or (e.left and e.bottom)) return .nesw;
    if (e.left or e.right) return .horizontal;
    if (e.top or e.bottom) return .vertical;
    return .arrow;
}

fn setCursorShape(shape: CursorShape) void {
    if (shape == cursor_shape) return;
    cursor_shape = shape;
    cursor_dirty = true;
}

fn tilePreviewRect(tile: frame.Tile) Rect {
    return frame.tileRect(workArea(), tile);
}

fn shellAction(action: u16) void {
    if (action == desktop.Action.keep_popup) return;
    const panel_was_open = openPanel() != null;
    dismissPanel();
    desktop.invalidateOverview();
    shell.notice = "";
    const old = shell.popup;
    shell.popup = .none;
    if (old == .spotlight) resetSpotlight();
    if (old == .switcher) shell.switcher = &.{};
    switch (action) {
        1...4 => launchApp(action - 1, false),
        desktop.Action.files => launchApp(4, false),
        desktop.Action.trash => launchApp(5, false),
        desktop.Action.hardware => if (!panel_was_open) launchApp(6, false),
        desktop.Action.browser => launchApp(7, false),
        desktop.Action.editor => launchApp(proto.App.editor, false),
        desktop.Action.viewer => launchApp(proto.App.viewer, false),
        desktop.Action.calculator => launchApp(proto.App.calculator, false),
        desktop.Action.settings_app => launchApp(proto.App.settings, false),
        desktop.Action.notifications => if (old != .notifications) {
            desktop.setNoteRows(note_store.count);
            note_store.markRead();
            note_store.dismissBanner();
            shell.popup = .notifications;
            pulp.print("desktop: notifications open, {d} kept\n", .{note_store.count});
        },
        desktop.Action.clear_notes => {
            note_store.clear();
            desktop.setNoteRows(0);
            shell.popup = .notifications;
            pulp.puts("desktop: notifications cleared\n");
        },
        desktop.Action.banner => note_store.dismissBanner(),
        desktop.Action.lock => lockScreen("the Orange menu"),
        desktop.Action.app_menu...desktop.Action.app_menu + menus.MAX_MENUS => {
            const i = action - desktop.Action.app_menu;
            if (i < bar.count and !(old == .app_menu and shell.open_menu == i)) {
                shell.open_menu = i;
                shell.popup = .app_menu;
                syncShell();
                desktop.layoutAppMenu(&screen, &shell);
                pulp.print("desktop: menu {s} open\n", .{bar.menus[i].title});
            }
        },
        desktop.Action.menu_item...desktop.Action.menu_item + menus.MAX_ITEMS - 1 => {
            if (old == .app_menu) menuChosen(action - desktop.Action.menu_item);
        },
        desktop.Action.menu => shell.popup = if (old == .menu) .none else .menu,
        desktop.Action.overview => shell.popup = if (old == .overview) .none else .overview,
        desktop.Action.settings => shell.popup = if (old == .settings) .none else .settings,
        desktop.Action.calendar => {
            shell.popup = if (old == .calendar) .none else .calendar;
            shell.month_offset = 0;
        },
        desktop.Action.previous_month, desktop.Action.next_month, desktop.Action.today => {
            shell.month_offset = switch (action) {
                desktop.Action.previous_month => @max(-1200, shell.month_offset - 1),
                desktop.Action.next_month => @min(1200, shell.month_offset + 1),
                else => 0,
            };
            shell.popup = .calendar;
        },
        desktop.Action.desktop => toggleDesktop(),
        desktop.Action.spotlight => if (old != .spotlight) openSpotlight(),
        desktop.Action.result...desktop.Action.result + spotlight.MAX_RESULTS - 1 => {
            const i = action - desktop.Action.result;
            if (old == .spotlight and i < shell.results.len) runResult(shell.results[i]);
        },
        desktop.Action.switch_item...desktop.Action.switch_item + MAX_WINDOWS - 1 => {
            const i = action - desktop.Action.switch_item;
            if (old == .switcher and i < shell.switcher.len) if (findWindowById(shell.switcher[i].id)) |wi| focusWindow(wi);
        },
        desktop.Action.new_terminal => launchApp(1, true),
        desktop.Action.reduce_motion => {
            reduce_motion = !reduce_motion;
            shell.popup = .settings;
            pulp.print("desktop: reduce motion {s}\n", .{if (reduce_motion) "on" else "off"});
            savePreferences();
        },
        desktop.Action.wallpaper...desktop.Action.wallpaper + 2 => {
            shell.palette = action - desktop.Action.wallpaper;
            for (0..window_count) |i| if (windows[i].panel) sendAppearance(i);
            shell.popup = .settings;
            pulp.print("desktop: theme {d} {s}\n", .{ shell.palette, desktop.THEME_NAMES[shell.palette] });
            savePreferences();
        },
        desktop.Action.window...desktop.Action.window + MAX_WINDOWS - 1 => {
            const idx = action - desktop.Action.window;
            if (idx < shell.count) if (findWindowById(shell.items[idx].id)) |wi| focusWindow(wi);
        },
        else => {},
    }
    if (shell.popup == .calendar and old == .calendar) {
        calendar_damage.add(desktop.popupRect(&screen, .calendar));
    } else if (shell.popup == .calendar and old == .none) {
        desktop.invalidateCalendar();
        calendar_opening = true;
        // The retained scene already contains current windows. Attach the
        // panel after pending scene damage instead of redrawing the desktop.
        addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
    } else if (old == .calendar and shell.popup == .none and
        (action == desktop.Action.calendar or action == desktop.Action.dismiss))
    {
        calendar_opening = false;
        desktop.invalidateCalendar();
        addDamage(desktop.popupExtent(&screen, .calendar));
        addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
    } else {
        calendar_opening = false;
        desktop.invalidateCalendar();
        addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
    }
    if (pulp.desktop_profile and shell.popup == .calendar)
        pulp.print("desktop: calendar offset {d}\n", .{shell.month_offset});
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
var calendar_damage: gfx.Damage = .{};
var calendar_opening = false;
var calendar_rebuilding = false;

fn addDamage(r: Rect) void {
    damage.add(r);
}

fn clearDamage() void {
    damage.count = 0;
    overview_damage.count = 0;
    calendar_damage.count = 0;
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
    // The arrow's tip is at (x, y); resize pointers are centred on it.
    return .{ .x = x - 12, .y = y - 12, .w = CURSOR_W + 12, .h = CURSOR_H + 12 };
}

fn drawCursor(s: *const gfx.Surface, x: i32, y: i32) void {
    switch (cursor_shape) {
        .arrow => ui.icon(s, .pointer, x, y, 20),
        .horizontal => ui.icon(s, .cursor_resize_h, x - 11, y - 11, 22),
        .vertical => ui.icon(s, .cursor_resize_v, x - 11, y - 11, 22),
        .nwse => ui.icon(s, .cursor_resize_nwse, x - 11, y - 11, 22),
        .nesw => ui.icon(s, .cursor_resize_nesw, x - 11, y - 11, 22),
    }
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

fn buildWallpaper(index: usize) void {
    if (wallpapers[index]) |*s| {
        var y: i32 = 0;
        while (y < s.height * s.scale) : (y += 1) {
            var x: i32 = 0;
            while (x < s.width * s.scale) : (x += 1) s.putPhysical(x, y, desktop.wallpaperPixel(x, y, s.width * s.scale, s.height * s.scale, index));
        }
    }
}

fn loadWallpaperSource(index: usize) void {
    const handle = pulp.shmCreate("", desktop.WALLPAPER_BYTES) catch return;
    const mapped = pulp.shmMap(handle, true) catch {
        pulp.handleClose(handle);
        return;
    };
    const fd = pulp.open(WALLPAPER_PATHS[index]) catch {
        pulp.handleClose(handle);
        return;
    };
    defer pulp.close(fd);
    var done: usize = 0;
    while (done < desktop.WALLPAPER_BYTES) {
        // The current read syscall caps a single validated user buffer at 4 KiB.
        const n = pulp.read(@intCast(fd), mapped[done..@min(done + 4096, desktop.WALLPAPER_BYTES)]) catch break;
        if (n == 0) break;
        done += n;
    }
    if (done != desktop.WALLPAPER_BYTES or !desktop.installWallpaperSource(index, mapped[0..done])) {
        pulp.print("desktop: wallpaper resource {d} unavailable\n", .{index});
        pulp.handleClose(handle);
        return;
    }
    // Keep this private SHM mapped: thumbnail paints sample it after boot.
    pulp.print("desktop: wallpaper resource {d} loaded\n", .{index});
}

fn paintWallpaper(clip: Rect) void {
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    const area = Rect.intersect(clip, full);
    if (area.isEmpty()) return;

    var y = area.y * screen.scale;
    while (y < area.bottom() * screen.scale) : (y += 1) {
        if (wallpapers[shell.palette]) |s| {
            const start: usize = @intCast(y * screen.stride + area.x * screen.scale);
            const len: usize = @intCast(area.w * screen.scale);
            @memcpy(screen.pixels[start..][0..len], s.pixels[start..][0..len]);
        } else {
            var x = area.x * screen.scale;
            while (x < area.right() * screen.scale) : (x += 1) screen.putPhysical(x, y, desktop.wallpaperPixel(x, y, screen.width * screen.scale, screen.height * screen.scale, shell.palette));
        }
    }
}

/// The backdrop under a fading window, so it can be blended back in.
var anim_scratch: ?gfx.Surface = null;

fn paintWindow(w: *const Window, active: bool, clip: Rect) void {
    if (!w.visible) return;
    if (!Rect.overlaps(w.damageRect(), clip)) return;
    if (w.anim) |a| {
        // Draw the window at its in-between frame, then mix it with what was
        // underneath. Content is scaled to the smaller frame for these few
        // frames; the client is never asked to redraw for motion.
        const now = frame_now;
        var moving = w.*;
        moving.anim = null;
        moving.rect = a.rect(now);
        const alpha = a.alpha(now);
        const area = Rect.intersect(clip, moving.damageRect());
        if (area.isEmpty() or alpha == 0) return;
        if (anim_scratch) |scratch| {
            copyRegion(&scratch, &screen, area);
            paintWindowNow(&moving, active, clip);
            screen.setClip(clip);
            if (alpha != 255) blendRegion(&screen, &scratch, area, alpha);
        } else paintWindowNow(&moving, active, clip);
        return;
    }
    paintWindowNow(w, active, clip);
}

fn copyRegion(to: *const gfx.Surface, from: *const gfx.Surface, area: Rect) void {
    var y = area.y * from.scale;
    while (y < area.bottom() * from.scale) : (y += 1) {
        const start: usize = @intCast(y * from.stride + area.x * from.scale);
        const len: usize = @intCast(area.w * from.scale);
        @memcpy(to.pixels[start..][0..len], from.pixels[start..][0..len]);
    }
}

/// screen = under + (screen - under) * alpha, over `area`.
fn blendRegion(s: *const gfx.Surface, under: *const gfx.Surface, area: Rect, alpha: u8) void {
    var y = area.y * s.scale;
    while (y < area.bottom() * s.scale) : (y += 1) {
        var x = area.x * s.scale;
        while (x < area.right() * s.scale) : (x += 1) {
            const i: usize = @intCast(y * s.stride + x);
            s.pixels[i] = gfx.lerp(under.pixels[i], s.pixels[i], alpha);
        }
    }
}

fn paintWindowNow(w: *const Window, active: bool, clip: Rect) void {
    screen.setClip(clip);
    gfx.windowShadow(&screen, w.rect, active);
    if (w.panel) {
        screen.frost(w.rect, 13, 0, 0);
        if (w.pixels) |src| window_body.paintPanel(&screen, w.rect, src);
        return;
    }
    const theme = desktop.themeColors(shell.palette);
    const radius = w.style.radius();
    if (!w.style.full_size) {
        // Diffuse the actual underlying desktop before painting opaque content.
        // Limit title writes to the title while rounding the full frame's top edge.
        screen.setClip(Rect.intersect(clip, w.titleBar()));
        screen.frostTop(w.titleBar(), radius, if (active) theme.frame else theme.frame_inactive, if (active) 238 else 221);
        if (w.pixels == null) {
            screen.setClip(Rect.intersect(clip, .{ .x = w.rect.x, .y = w.rect.y + TITLE_H, .w = w.rect.w, .h = w.rect.h - TITLE_H }));
            screen.rounded(w.rect, radius, theme.surface, 255);
        }
        screen.setClip(clip);
        if (theme.edge_highlights) screen.rounded(.{ .x = w.rect.x + radius + 1, .y = w.rect.y, .w = w.rect.w - radius * 2 - 2, .h = 1 }, 0, theme.rim, 120);
        screen.rounded(.{ .x = w.rect.x + 1, .y = w.rect.y + TITLE_H - 1, .w = w.rect.w - 2, .h = 1 }, 0, theme.muted, 38);
        // The title, centred; cut to fit between the buttons and the edge.
        const room = w.rect.w - 2 * (frame.BUTTON_X_TITLE + frame.BUTTON_PITCH * 3 + 8);
        var len = w.title_len;
        while (len > 0 and font.textWidth(w.title()[0..len], 1) > room) len -= 1;
        const title = w.title()[0..len];
        font.drawText(&screen, title, w.rect.x + @divTrunc(w.rect.w - font.textWidth(title, 1), 2), w.rect.y + 10, 1, if (active) theme.frame_text else theme.muted);
    }

    // Client content: copy the client's buffer into place. Peel never draws
    // inside a client window, and the client never touches the screen.
    screen.setClip(clip);
    if (w.pixels) |src| {
        window_body.paint(&screen, w.rect, w.contentRect(), src, w.client_w, w.client_h, w.stride, radius, w.style.full_size);
    } else {
        font.drawText(&screen, "waiting for a client...", w.rect.x + 12, w.rect.y + TITLE_H + 14, 1, theme.muted);
    }

    // Window buttons last: in a full-size window they sit on the client's bar.
    const colors = [_]u32{ 0xFF5F57, 0xFEBC2E, 0x28C840 };
    const group_hot = dragging == null and resizing == null and w.style.buttonGroup(w.rect).contains(cursor_x, cursor_y);
    for (0..3) |i| {
        if (i == 0 and !w.closable) continue;
        if (i == 2 and !w.zoomable()) continue;
        const c = w.control(@intCast(i));
        const cx = c.x + @divTrunc(frame.BUTTON_FRAME, 2);
        const cy = c.y + 8;
        const fill = if (active or group_hot) colors[i] else gfx.lerp(theme.frame_inactive, theme.muted, 65);
        // A darker rim of the same colour, like the Mac's, keeps the circle
        // crisp on a light bar.
        screen.circle(cx, cy, @divTrunc(frame.BUTTON_D, 2), gfx.lerp(fill, 0x000000, 28));
        screen.circle(cx, cy, @divTrunc(frame.BUTTON_D, 2) - 1, fill);
        // Hovering the group shows all three symbols, as on the Mac.
        if (group_hot) ui.iconTint(&screen, ([_]ui.Icon{ .close, .minimize, .maximize })[i], cx - 5, cy - 5, 10, gfx.lerp(fill, 0x000000, 150));
    }
}

/// Repaint everything intersecting `area`, back to front.
fn expandedDamage(area: Rect, retained_calendar: bool) Rect {
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
            if (w.visible) clip = gfx.expandForGlass(clip, if (w.panel) w.rect else w.titleBar());
        }
        var state = shell;
        if (retained_calendar) state.popup = .none;
        clip = Rect.intersect(desktop.expandDamage(&screen, &state, clip), full);
        if (clip.x == before.x and clip.y == before.y and clip.w == before.w and clip.h == before.h) break;
    }

    return clip;
}

fn composite(clip: Rect) void {
    if (clip.isEmpty()) return;
    if (lock.active) {
        // Nothing of the session is drawn while locked: wallpaper, then
        // the lock screen.
        screen.setClip(clip);
        defer screen.resetClip();
        paintWallpaper(clip);
        syncShell();
        shell.lock = .{ .active = true, .name = if (account) |*a| a.name() else "", .typed = lock.input.len, .message = lock.message };
        desktop.paintLock(&screen, &shell);
        return;
    }
    shell.lock = .{};
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
        paintTilePreview(clip);
        paintWindow(&windows[moving.?], true, clip);
    } else {
        drag_backdrop_valid = false;
        paintWallpaper(clip);
        const top = activeWindow();
        for (z_order[0..window_count]) |idx| {
            if (idx == top and moving == top) paintTilePreview(clip);
            paintWindow(&windows[idx], top == idx, clip);
        }
    }

    syncShell();
    const popup = shell.popup;
    if (popup == .calendar and !calendar_opening and !calendar_rebuilding and !desktop.calendarUnderlayValid())
        desktop.captureCalendarUnderlay(&screen);
    if (calendar_opening or calendar_rebuilding) shell.popup = .none;
    desktop.paint(&screen, &shell);
    shell.popup = popup;
}

/// Where a dragged window will tile: a soft accent-tinted area with a
/// bright edge, under the window being dragged.
fn paintTilePreview(clip: Rect) void {
    if (tile_preview == .none) return;
    const r = tilePreviewRect(tile_preview);
    if (!Rect.overlaps(r, clip)) return;
    const theme = desktop.themeColors(shell.palette);
    screen.setClip(clip);
    screen.rounded(r, 12, gfx.lerp(theme.accent, 0xFFFFFF, 40), 110);
    screen.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, 11, gfx.lerp(theme.accent, 0xFFFFFF, 120), 70);
    screen.rounded(.{ .x = r.x + 2, .y = r.y + 2, .w = r.w - 4, .h = r.h - 4 }, 10, gfx.lerp(theme.accent, 0xFFFFFF, 40), 110);
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
    const is_panel = req.flags & proto.WindowFlags.panel != 0;
    if (is_panel and (w > screen.width - 24 or h > screen.height - desktop.BAR_H - 24)) {
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(reply);
        return;
    }

    const title_len = @min(req.title_len, 48);
    const name_len = @min(req.shm_name_len, 32);
    const resizable = !is_panel and req.flags & proto.WindowFlags.resizable != 0 and
        req.capacity_w >= req.width and req.capacity_h >= req.height and req.capacity_w <= 4096 and req.capacity_h <= 4096;
    const full_size = !is_panel and req.flags & proto.WindowFlags.full_size_content != 0;
    const cap_w: i32 = if (resizable) @intCast(req.capacity_w) else w;
    const cap_h: i32 = if (resizable) @intCast(req.capacity_h) else h;

    // Map the client's buffer. Peel takes it read-only in spirit: it copies
    // out of it and never writes back, so a misbehaving client can corrupt
    // its own window and nothing else.
    const shm = pulp.shmOpen(req.shm_name[0..name_len]) catch {
        pulp.puts("peel: client buffer not found\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(reply);
        return;
    };
    // The buffer must hold everything the client says it does, or reading
    // it would fault the compositor.
    const needed: usize = @intCast(@as(i64, cap_w) * cap_h * 4 * screen.scale * screen.scale);
    if ((pulp.shmSize(shm) catch 0) < needed) {
        pulp.puts("peel: client buffer smaller than the window\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(shm);
        pulp.handleClose(reply);
        return;
    }
    const pixels = pulp.shmMap(shm, false) catch {
        pulp.puts("peel: cannot map client buffer\n");
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(shm);
        pulp.handleClose(reply);
        return;
    };

    const style = frame.Style{ .full_size = full_size, .bar_h = if (full_size) @intCast(@min(@max(req.bar_height, 24), 80)) else TITLE_H };
    const size = style.frameSize(w, h);
    const frame_w = if (is_panel) w else size[0];
    const frame_h = if (is_panel) h else size[1];
    const idx = addWindow(
        .{ .x = if (is_panel) screen.width - w - 12 else @max(0, @min(req.x, screen.width - frame_w)), .y = if (is_panel) desktop.BAR_H + 8 else @max(desktop.BAR_H + 10, @min(req.y, screen.height - desktop.DOCK_H - 30 - frame_h)), .w = frame_w, .h = frame_h },
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
    windows[idx].stride = cap_w * screen.scale;
    windows[idx].style = if (is_panel) .{} else style;
    windows[idx].resizable = resizable;
    windows[idx].cap_w = cap_w;
    windows[idx].cap_h = cap_h;
    windows[idx].min_w = if (resizable) @max(160, @min(@as(i32, @intCast(req.min_w)), w)) else w;
    windows[idx].min_h = if (resizable) @max(100, @min(@as(i32, @intCast(req.min_h)), h)) else h;
    windows[idx].reply_port = reply;
    windows[idx].buffer_handle = shm;
    windows[idx].owner_pid = req.pid;
    windows[idx].closable = req.flags & proto.WindowFlags.closable != 0;
    windows[idx].panel = is_panel;
    windows[idx].app = if (req.app != 0 and req.app < desktop.APP_COUNT) req.app else @intCast(appIndex(windows[idx].title()));
    windows[idx].confirms_close = !is_panel and req.flags & proto.WindowFlags.confirms_close != 0;
    windows[idx].last_msg_ms = pulp.uptimeMs();
    pending_apps[windows[idx].app] = -1;

    // A shared reply port would deliver one client's answer to whichever
    // client happened to read first, so each process owns its own port.
    sendCreated(reply, windows[idx].id, req.width, req.height);
    if (is_panel) {
        sendAppearance(idx);
        pulp.puts("desktop: control panel opened\n");
    }

    pulp.print("peel: window {d} \"{s}\" {d}x{d} for pid {d}\n", .{
        windows[idx].id, windows[idx].title(), w, h, req.pid,
    });
    logFrame(idx, "opened");
    // A document this app was started for: hand it over now.
    for (&pending_open) |*slot| if (slot.pid == req.pid) {
        _ = pulp.portSend(reply, proto.Op.open_file, slot.path[0..slot.len]) catch {};
        slot.pid = -1;
    };

    // A window opens by growing from 92% and fading in (not panels).
    if (!is_panel) startAnim(idx, frame.openFrom(windows[idx].rect), windows[idx].rect, 0, 255, false);
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

/// Where a window and its content are, for tests and for reading logs.
fn logFrame(idx: usize, what: []const u8) void {
    const w = &windows[idx];
    const c = w.contentRect();
    pulp.print("peel: frame {d} {s} {d},{d} {d}x{d} content {d},{d} {d}x{d}{s}\n", .{
        w.id,  what, w.rect.x, w.rect.y, w.rect.w, w.rect.h, c.x, c.y, c.w, c.h,
        if (w.resizable) " resizable" else "",
    });
}

/// Ask a resizable client to draw at the size of `want`, unless it is
/// still drawing the last size asked for (one configure at a time, so a
/// fast drag never queues work the client can not keep up with).
fn requestSize(idx: usize, want: Rect, edges: frame.Edges) void {
    const w = &windows[idx];
    w.want = want;
    w.want_edges = edges;
    if (w.configure_sent != null and pulp.uptimeMs() -| w.configure_at < 1000) return;
    sendConfigure(idx);
}

fn sendConfigure(idx: usize) void {
    const w = &windows[idx];
    const want = w.want orelse return;
    const c = w.style.content(want);
    const cw = @import("std").math.clamp(c.w, w.min_w, w.cap_w);
    const ch = @import("std").math.clamp(c.h, w.min_h, w.cap_h);
    if (cw == w.client_w and ch == w.client_h) {
        // Same size: only the position changes, which needs no redraw.
        placeWindow(idx, frame.anchored(want, w.want_edges, w.rect.w, w.rect.h));
        w.want = null;
        w.configure_sent = null;
        return;
    }
    const msg = proto.Configure{ .window_id = w.id, .width = @intCast(cw), .height = @intCast(ch) };
    _ = pulp.portSend(w.reply_port, proto.Op.configure, @import("std").mem.asBytes(&msg)) catch return;
    w.configure_sent = .{ cw, ch };
    w.configure_at = pulp.uptimeMs();
}

fn placeWindow(idx: usize, r: Rect) void {
    const w = &windows[idx];
    if (w.rect.x == r.x and w.rect.y == r.y and w.rect.w == r.w and w.rect.h == r.h) return;
    addDamage(w.damageRect());
    w.rect = r;
    addDamage(w.damageRect());
    drag_backdrop_valid = false;
}

/// The client has drawn a new size: show it, against the edges being held.
fn handleResized(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.Configure)) return;
    const c: *align(1) const proto.Configure = @ptrCast(payload.ptr);
    const idx = findWindowById(c.window_id) orelse return;
    const w = &windows[idx];
    if (!w.resizable) return;
    const cw = @import("std").math.clamp(@as(i32, @intCast(@min(c.width, 4096))), w.min_w, w.cap_w);
    const ch = @import("std").math.clamp(@as(i32, @intCast(@min(c.height, 4096))), w.min_h, w.cap_h);
    w.client_w = cw;
    w.client_h = ch;
    w.revision +%= 1;
    const size = w.style.frameSize(cw, ch);
    // While the window is being moved, it stays under the pointer.
    const want = if (dragging == w.id) w.rect else w.want orelse w.rect;
    placeWindow(idx, frame.anchored(want, if (dragging == w.id) .{} else w.want_edges, size[0], size[1]));
    addDamage(w.damageRect());
    w.configure_sent = null;
    if (pulp.desktop_profile) pulp.print("peel: resized {d} to {d}x{d}\n", .{ w.id, cw, ch });
    // The user kept dragging while the client drew: ask for the latest size.
    if (w.want) |next| {
        const nc = w.style.content(next);
        if (@import("std").math.clamp(nc.w, w.min_w, w.cap_w) != cw or @import("std").math.clamp(nc.h, w.min_h, w.cap_h) != ch) {
            sendConfigure(idx);
        } else {
            w.want = null;
            logFrame(idx, "resized");
        }
    }
}

/// A full-size client's own toolbar was pressed: move the window with the
/// pointer, as if its title bar had been (double press: zoom).
fn handleMoveRequest(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.Destroy)) return;
    const d: *align(1) const proto.Destroy = @ptrCast(payload.ptr);
    const idx = findWindowById(d.window_id) orelse return;
    if (!windows[idx].visible or windows[idx].panel) return;
    // Only for the press the client was just sent, so a stale or unasked
    // request cannot take the window later.
    if (last_client_press != d.window_id or pulp.uptimeMs() -| last_client_press_ms > 1000) return;
    last_client_press = null;
    if (pointer_capture == d.window_id and buttons & 1 != 0) {
        // Release the client's press so it does not stay pressed.
        sendInput(idx, pulp.EV_MOUSE, 0, 0, -10000, -10000);
        pointer_capture = null;
        hover_window = null;
        titlePress(idx);
    } else {
        // The button was already up (a quick click): it still counts
        // towards a double click, but there is nothing to drag.
        titleClick(idx);
    }
}

/// A click on a title area with no drag: the second of two zooms.
fn titleClick(idx: usize) void {
    const now = pulp.uptimeMs();
    const id = windows[idx].id;
    if (last_title_id == id and frame.isDoubleClick(last_title_ms, last_title_x, last_title_y, now, cursor_x, cursor_y)) {
        last_title_ms = null;
        zoomWindow(idx);
        return;
    }
    last_title_ms = now;
    last_title_x = cursor_x;
    last_title_y = cursor_y;
    last_title_id = id;
}

fn handleCommit(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.Commit)) return;
    const c: *align(1) const proto.Commit = @ptrCast(payload.ptr);

    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        if (windows[i].id != c.window_id) continue;
        windows[i].revision +%= 1;
        windows[i].last_msg_ms = pulp.uptimeMs();
        notify_app = windows[i].app;
        if (shell.popup == .overview and !windows[i].panel) {
            // Workspace-switcher semantics: hold the backdrop while live
            // previews update. On dismissal shellAction repaints the whole
            // desktop from current client buffers. A clock tick must not
            // trigger a full blurred multi-window reconstruction every second.
            syncShell();
            for (shell.items[0..shell.count], 0..) |item, slot| if (item.id == windows[i].id) {
                overview_damage.add(desktop.windowCard(&screen, slot));
                break;
            };
            return;
        }
        if (!windows[i].visible) return;
        if (windows[i].anim != null) return; // repainted every frame anyway
        if (windows[i].zoomed and !windows[i].resizable) {
            // A fixed-size window zoomed by scaling: any change moves pixels.
            addDamage(windows[i].contentRect());
            return;
        }
        const content = windows[i].contentRect();
        // Client coordinates are relative to its own buffer; translate into
        // screen space before damaging.
        // The outside one-point rim repeats the client's edge pixels. Include
        // it when that edge changes, or live content would leave a stale seam.
        var changed = Rect.intersect(.{ .x = c.x, .y = c.y, .w = c.w, .h = c.h }, .{ .x = 0, .y = 0, .w = content.w, .h = content.h });
        if (changed.isEmpty()) return;
        const right_edge = changed.right() == content.w;
        const bottom_edge = changed.bottom() == content.h;
        if (changed.x == 0) {
            changed.x -= 1;
            changed.w += 1;
        }
        if (right_edge) changed.w += 1;
        if (bottom_edge) changed.h += 1;
        changed.x += content.x;
        changed.y += content.y;
        addDamage(changed);
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
                // A window can be dragged as large as the area below the menu
                // bar, so that is what a resizable client allocates.
                const info = proto.DisplayInfo{ .scale = @intCast(screen.scale), .max_width = @intCast(screen.width - frame.BORDER * 2), .max_height = @intCast(screen.height - desktop.BAR_H - frame.BORDER) };
                _ = pulp.portSend(reply, proto.Op.display_info_reply, @import("std").mem.asBytes(&info)) catch {};
                pulp.handleClose(reply);
            },
            proto.Op.create_window => handleCreateWindow(buf[0..m.len]),
            proto.Op.commit => handleCommit(buf[0..m.len]),
            proto.Op.destroy => handleDestroy(buf[0..m.len]),
            proto.Op.resized => handleResized(buf[0..m.len]),
            proto.Op.open_document => if (!lock.active) openDocument(buf[0..m.len]),
            proto.Op.set_title => if (m.len >= 4) {
                if (findWindowById(std.mem.readInt(u32, buf[0..4], .little))) |idx| {
                    var clean: [48]u8 = undefined;
                    const n = @min(m.len - 4, 48);
                    for (buf[4..][0..n], 0..) |c, i| clean[i] = if (c >= 32 and c <= 126) c else ' ';
                    windows[idx].setTitle(clean[0..n]);
                    addDamage(windows[idx].damageRect());
                    chromeDamage();
                }
            },
            proto.Op.set_menu => if (m.len >= 4) {
                if (findWindowById(std.mem.readInt(u32, buf[0..4], .little))) |idx| {
                    const n = @min(m.len - 4, proto.MENU_MAX_BYTES);
                    @memcpy(windows[idx].menu_buf[0..n], buf[4..][0..n]);
                    windows[idx].menu_len = n;
                    windows[idx].menu_serial +%= 1;
                    syncShell();
                }
            },
            proto.Op.notify => if (m.len >= @sizeOf(proto.Notify)) {
                const n: *align(1) const proto.Notify = @ptrCast(&buf);
                // The sender's app is the window that most recently spoke;
                // a program with no window posts as the system.
                postNote(n.title[0..@min(n.title_len, 48)], n.body[0..@min(n.body_len, 120)], notify_app);
            },
            proto.Op.set_preference => if (m.len >= @sizeOf(proto.Preference)) {
                const pref: *align(1) const proto.Preference = @ptrCast(&buf);
                setPreference(pref.key, pref.value);
            },
            proto.Op.get_preferences => if (m.len == 8) {
                const pid = @as(*align(1) const i64, @ptrCast(&buf)).*;
                var name_buf: [32]u8 = undefined;
                if (pulp.portConnect(proto.replyPortName(&name_buf, pid))) |reply| {
                    sendPreferences(reply);
                    pulp.handleClose(reply);
                } else |_| {}
            },
            proto.Op.move_request => handleMoveRequest(buf[0..m.len]),
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

/// The app whose window most recently committed, for attributing a
/// notification that follows (apps notify right after drawing).
var notify_app: u32 = 0;

// ── Preferences, account and lock (docs/design/014, M5 and M8) ────────────

const LockState = struct {
    active: bool = false,
    input: ui.TextInput(account_mod.MAX_PASSWORD) = .{},
    message: []const u8 = "",
    failures: u32 = 0,
};
var lock: LockState = .{};
var account: ?account_mod.Account = null;
/// Minutes without input before the screen locks (0: never).
var lock_minutes: u32 = 0;
var last_input_ms: u64 = 0;

fn loadAccount() void {
    var buf: [512]u8 = undefined;
    const fd = pulp.open(account_mod.PATH) catch {
        account = null;
        return;
    };
    defer pulp.close(fd);
    const n = pulp.read(@intCast(fd), &buf) catch 0;
    account = account_mod.Account.parse(buf[0..n]);
    pulp.print("desktop: account {s}\n", .{if (account != null) "found" else "file unreadable"});
}

/// Lock the screen: nothing behind it is shown or receives input until
/// the password is entered. Without an account there is nothing to ask for.
fn lockScreen(why: []const u8) void {
    if (lock.active) return;
    if (account == null) {
        shell.notice = "Set a password in Settings to lock the screen.";
        return;
    }
    if (hover_window) |old| sendInputById(old, pulp.EV_MOUSE, 0, 0, -10000, -10000);
    hover_window = null;
    pointer_capture = null;
    dragging = null;
    resizing = null;
    shell.popup = .none;
    lock = .{ .active = true };
    pulp.print("desktop: locked ({s})\n", .{why});
    addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
}

fn lockKey(e: *const pulp.InputEvent) void {
    if (e.code == keymap.LSHIFT or e.code == keymap.RSHIFT) shift_held = e.isPress();
    if (!e.isPress()) return;
    const typing = desktop.lockTypingRect(&screen);
    if (e.code == keymap.ENTER) {
        const acct = account orelse return;
        if (lock.input.len == 0) return;
        if (acct.check(lock.input.text())) {
            // Wipe the typed password before anything else.
            @memset(&lock.input.buf, 0);
            lock = .{};
            last_input_ms = pulp.uptimeMs();
            pulp.puts("desktop: unlocked\n");
            addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
            return;
        }
        @memset(&lock.input.buf, 0);
        lock.input.clear();
        lock.failures += 1;
        lock.message = "Wrong password. Try again.";
        pulp.print("desktop: wrong password ({d})\n", .{lock.failures});
        addDamage(typing);
        return;
    }
    if (e.code == keymap.ESC) {
        @memset(&lock.input.buf, 0);
        lock.input.clear();
    } else if (e.code == keymap.BACKSPACE) {
        _ = lock.input.backspace();
    } else if (e.value & 2 == 0) {
        const ch = keymap.translate(e.code, shift_held);
        if (!lock.input.insert(ch)) return;
    } else return;
    lock.message = "";
    addDamage(typing);
}

fn sendPreferences(reply: i64) void {
    const prefs = proto.Preferences{
        .theme = @intCast(shell.palette),
        .reduce_motion = @intFromBool(reduce_motion),
        .lock_minutes = lock_minutes,
        .kept = @intFromBool(shell.prefs_kept),
        .has_password = @intFromBool(account != null),
        .screen_width = @intCast(screen.width),
        .screen_height = @intCast(screen.height),
        .scale = @intCast(screen.scale),
    };
    _ = pulp.portSend(reply, proto.Op.preferences, std.mem.asBytes(&prefs)) catch {};
}

/// Tell every open Settings window the preferences changed.
fn broadcastPreferences() void {
    for (windows[0..window_count]) |*w| {
        if (w.app == proto.App.settings and w.reply_port >= 0) sendPreferences(w.reply_port);
    }
}

fn setPreference(key: u32, value: u32) void {
    switch (key) {
        proto.Pref.theme => if (value < desktop.THEME_NAMES.len) {
            shell.palette = value;
            for (0..window_count) |i| if (windows[i].panel) sendAppearance(i);
            pulp.print("desktop: theme {d} {s}\n", .{ shell.palette, desktop.THEME_NAMES[shell.palette] });
            savePreferences();
            desktop.invalidateCalendar();
            addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
        },
        proto.Pref.reduce_motion => {
            reduce_motion = value != 0;
            pulp.print("desktop: reduce motion {s}\n", .{if (reduce_motion) "on" else "off"});
            savePreferences();
        },
        proto.Pref.lock_minutes => {
            lock_minutes = @min(value, 240);
            pulp.print("desktop: lock after {d} minutes\n", .{lock_minutes});
            savePreferences();
        },
        proto.Pref.lock_now => lockScreen("Settings"),
        proto.Pref.account_changed => loadAccount(),
        else => return,
    }
    broadcastPreferences();
}

// ── Spotlight's file list (M3) ─────────────────────────────────────────────

const DOCUMENTS = "/data/Documents";
var spot_files: [spotlight.MAX_FILES]spotlight.FileEntry = undefined;
var spot_paths: [spotlight.MAX_FILES][160]u8 = undefined;
var spot_path_len: [spotlight.MAX_FILES]u8 = undefined;
var spot_count: usize = 0;

/// List Documents and the folders in it (one level down): what Spotlight
/// can find. Read when Spotlight opens, so it is never stale for long.
fn indexDocuments() void {
    spot_count = 0;
    indexFolder(DOCUMENTS, true);
    pulp.print("desktop: spotlight sees {d} documents\n", .{spot_count});
}

fn indexFolder(dir: []const u8, descend: bool) void {
    var entries: [48]pulp.DirEntry = undefined;
    const n = pulp.readdirPage(dir, &entries, 0) catch return;
    for (entries[0..n]) |*e| {
        if (spot_count == spot_files.len) return;
        const name = e.nameSlice();
        if (name.len == 0 or name[0] == '.') continue;
        const full = std.fmt.bufPrint(&spot_paths[spot_count], "{s}/{s}", .{ dir, name }) catch continue;
        spot_path_len[spot_count] = @intCast(full.len);
        // The name and folder shown are slices of the stored path.
        const stored = spot_paths[spot_count][0..full.len];
        spot_files[spot_count] = .{
            .name = stored[dir.len + 1 ..],
            .where = stored[@min(stored.len, "/data/".len)..dir.len],
            .glyph = spotlight.fileGlyph(name, e.isDir()),
        };
        const index = spot_count;
        spot_count += 1;
        if (descend and e.isDir()) indexFolder(spot_paths[index][0..spot_path_len[index]], false);
    }
}

var dragging: ?u32 = null;
/// An edge or corner being dragged: which, and the frame and pointer when
/// the press began.
var resizing: ?struct { id: u32, edges: frame.Edges, start: Rect, px: i32, py: i32 } = null;
/// Dragging a tiled or zoomed window first gives it back its own size.
var drag_restore: bool = false;
var drag_start_x: i32 = 0;
var drag_start_y: i32 = 0;
/// The tile a drag to the screen edge offers, drawn as a translucent area.
var tile_preview: frame.Tile = .none;
var last_title_ms: ?u64 = null;
var last_title_x: i32 = 0;
var last_title_y: i32 = 0;
var last_title_id: u32 = 0;
/// The window that last received a button press, and when: the only one
/// whose move request is honoured.
var last_client_press: ?u32 = null;
var last_client_press_ms: u64 = 0;
const CursorShape = enum { arrow, horizontal, vertical, nwse, nesw };
var cursor_shape: CursorShape = .arrow;
var pointer_capture: ?u32 = null;
var hover_window: ?u32 = null;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var buttons: u8 = 0;
var panel_dismiss_capture = false;
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
    flushInput(w);
    const motion_only = kind == pulp.EV_MOUSE and code == w.sent_buttons;
    if (kind == pulp.EV_MOUSE) w.sent_buttons = code;
    if (w.backlog_len == 0) {
        const bytes: [*]const u8 = @ptrCast(&msg);
        if (pulp.portSend(w.reply_port, proto.Op.input, bytes[0..@sizeOf(proto.Input)])) |_| return else |_| {}
    }
    if (motion_only) return; // the next motion supersedes it
    if (w.backlog_len == w.backlog.len) {
        pulp.puts("peel: input backlog full; event dropped\n");
        return;
    }
    w.backlog[w.backlog_len] = msg;
    w.backlog_len += 1;
}

/// Send what the client's port had no room for, oldest first.
fn flushInput(w: *Window) void {
    if (w.reply_port < 0) return;
    var done: usize = 0;
    while (done < w.backlog_len) : (done += 1) {
        const bytes: [*]const u8 = @ptrCast(&w.backlog[done]);
        _ = pulp.portSend(w.reply_port, proto.Op.input, bytes[0..@sizeOf(proto.Input)]) catch break;
    }
    if (done == 0) return;
    @import("std").mem.copyForwards(proto.Input, w.backlog[0 .. w.backlog_len - done], w.backlog[done..w.backlog_len]);
    w.backlog_len -= done;
}

fn sendInputById(id: u32, kind: u8, code: u8, value: u8, sx: i32, sy: i32) void {
    const idx = findWindowById(id) orelse return;
    sendInput(idx, kind, code, value, sx, sy);
}

fn requestClose(id: u32) void {
    const idx = findWindowById(id) orelse return;
    const msg = proto.Destroy{ .window_id = id };
    const bytes: [*]const u8 = @ptrCast(&msg);
    if (windows[idx].confirms_close) {
        // A document window is asked, and decides (it may have unsaved
        // changes). Only a client that has not answered anything since the
        // last ask, two seconds on, is closed over its head.
        const w = &windows[idx];
        const now = pulp.uptimeMs();
        const stuck = w.close_asked_ms != 0 and w.last_msg_ms < w.close_asked_ms and now -| w.close_asked_ms > 2000;
        if (!stuck) {
            w.close_asked_ms = now;
            _ = pulp.portSend(w.reply_port, proto.Op.close_requested, bytes[0..@sizeOf(proto.Destroy)]) catch {};
            pulp.print("desktop: asked window {d} to close\n", .{id});
            return;
        }
    }
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
    last_input_ms = pulp.uptimeMs();
    // Locked: the pointer moves, and nothing else happens.
    if (lock.active) return;
    if (panel_dismiss_capture) {
        if (!is_down) panel_dismiss_capture = false;
        return;
    }
    if (is_down and !was_down and pointer_capture == null) if (openPanel()) |idx| {
        if (!windows[idx].rect.contains(cursor_x, cursor_y)) {
            dismissPanel();
            panel_dismiss_capture = true;
            return;
        }
    };
    // Entering or leaving a window's button group shows or hides the symbols.
    for ([_][2]i32{ .{ prev_cursor_x, prev_cursor_y }, .{ cursor_x, cursor_y } }) |at| {
        if (shell.popup != .none) break;
        const idx = windowAt(at[0], at[1]) orelse continue;
        if (windows[idx].panel) continue;
        const g = windows[idx].style.buttonGroup(windows[idx].rect);
        if (g.contains(prev_cursor_x, prev_cursor_y) != g.contains(cursor_x, cursor_y)) addDamage(g);
    }
    syncShell();
    const hit = desktop.hit(&screen, &shell, cursor_x, cursor_y);
    if (hit != shell.hover) {
        addDamage(desktop.hoverDamage(&screen, &shell, shell.hover, hit));
        if (shell.popup == .calendar) {
            for ([_]u16{ shell.hover, hit }) |action| {
                if (desktop.calendarHover(action)) calendar_damage.add(desktop.calendarButton(&screen, action));
            }
        }
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
    if (dragging == null and resizing == null and control_pressed == null and pointer_capture == null and (hit != 0 or shell_pressed != null)) {
        setCursorShape(.arrow);
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

    // Hovering an edge shows the resize pointer.
    if (!is_down and resizing == null and dragging == null) {
        setCursorShape(if (pointer_capture == null) if (edgeTarget(cursor_x, cursor_y)) |t| shapeFor(t.edges) else .arrow else .arrow);
    }

    if (is_down and !was_down and pointer_capture == null) {
        if (edgeTarget(cursor_x, cursor_y)) |t| {
            focusWindow(t.idx);
            const w = &windows[t.idx];
            // Resizing a tiled window keeps its new size as its own.
            w.tiled = .none;
            w.zoomed = false;
            resizing = .{ .id = w.id, .edges = t.edges, .start = w.rect, .px = cursor_x, .py = cursor_y };
            setCursorShape(shapeFor(t.edges));
            if (hover_window) |old| sendInputById(old, pulp.EV_MOUSE, 0, 0, -10000, -10000);
            hover_window = null;
            pulp.print("desktop: resize window {d} from {d}x{d}\n", .{ w.id, w.rect.w, w.rect.h });
            return;
        }
        if (windowAt(cursor_x, cursor_y)) |idx| {
            focusWindow(idx);
            const id = windows[idx].id;
            var control: i32 = 0;
            while (control < 3 and !windows[idx].panel) : (control += 1) {
                if (control == 0 and !windows[idx].closable) continue;
                if (windows[idx].control(control).contains(cursor_x, cursor_y)) {
                    control_pressed = .{ .id = id, .control = control };
                    break;
                }
            }
            if (control_pressed != null) {
                // handled on release
            } else if (windows[idx].titleBar().contains(cursor_x, cursor_y)) {
                titlePress(idx);
            } else {
                pointer_capture = id;
                last_client_press = id;
                last_client_press_ms = pulp.uptimeMs();
            }
        }
    }

    if (resizing) |r| {
        const idx = findWindowById(r.id) orelse {
            resizing = null;
            return;
        };
        if (is_down) {
            const want = frame.resized(r.start, r.edges, cursor_x - r.px, cursor_y - r.py, windows[idx].limits());
            requestSize(idx, want, r.edges);
            return;
        }
        resizing = null;
        setCursorShape(.arrow);
        if (windows[idx].want == null) logFrame(idx, "resized");
        return;
    }

    if (dragging) |id| if (is_down) {
        const idx = findWindowById(id) orelse {
            dragging = null;
            return;
        };
        const w = &windows[idx];
        if (drag_restore and (@abs(cursor_x - drag_start_x) > 3 or @abs(cursor_y - drag_start_y) > 3)) {
            // Pulling a tiled window away gives it back its own size, with
            // the pointer keeping its place along the title.
            drag_restore = false;
            const old = w.restore_rect;
            drag_dx = @divTrunc(drag_dx * old.w, @max(1, w.rect.w));
            w.tiled = .none;
            w.zoomed = false;
            requestSize(idx, .{ .x = cursor_x - drag_dx, .y = cursor_y - drag_dy, .w = old.w, .h = old.h }, .{});
        }
        // Damage both where the window was and where it is going, or the old
        // position is left painted on screen.
        addDamage(w.damageRect());
        const min_x = -w.rect.w + 40;
        const max_x = screen.width - 40;
        w.rect.x = @max(min_x, @min(cursor_x - drag_dx, max_x));
        w.rect.y = @max(desktop.BAR_H, @min(cursor_y - drag_dy, screen.height - desktop.DOCK_H - TITLE_H - 22));
        addDamage(w.damageRect());
        // Offer a tile at the screen edges (resizable windows only).
        const tile = if (w.resizable) frame.tileAt(screen.width, desktop.BAR_H, cursor_x, cursor_y) else frame.Tile.none;
        if (tile != tile_preview) {
            if (tile_preview != .none) addDamage(tilePreviewRect(tile_preview));
            tile_preview = tile;
            if (tile != .none) {
                addDamage(tilePreviewRect(tile));
                pulp.print("desktop: tile preview {s}\n", .{@tagName(tile)});
            }
        }
    };

    if (!is_down and was_down) {
        if (control_pressed) |pressed| {
            if (findWindowById(pressed.id)) |idx| {
                if (windows[idx].control(pressed.control).contains(cursor_x, cursor_y)) {
                    switch (pressed.control) {
                        0 => requestClose(pressed.id),
                        1 => minimizeWindow(idx),
                        2 => zoomWindow(idx),
                        else => {},
                    }
                }
            }
            control_pressed = null;
            return;
        }
        if (dragging) |id| if (findWindowById(id)) |idx| {
            if (tile_preview != .none) {
                addDamage(tilePreviewRect(tile_preview));
                const tile = tile_preview;
                tile_preview = .none;
                tileWindow(idx, tile);
            } else logFrame(idx, "moved");
        };
        tile_preview = .none;
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

// ── Spotlight and the app switcher (docs/design/014, M1) ───────────────────

var query_buf: [spotlight.MAX_QUERY]u8 = undefined;
var query_len: usize = 0;
var results: [spotlight.MAX_RESULTS]spotlight.Result = undefined;
var number_buf: [48]u8 = undefined;
/// What the last painted Spotlight showed; a difference repaints it.
var shown_rows: usize = 0;
var shown_key: u64 = 0;
var shift_held = false;
var switch_items: [MAX_WINDOWS]desktop.SwitchItem = undefined;

fn openSpotlight() void {
    indexDocuments();
    query_len = 0;
    shell.selected = 0;
    shell.popup = .spotlight;
    refreshSpotlight();
    pulp.puts("desktop: spotlight open\n");
}

/// Search again for the current query and open windows, and repaint
/// Spotlight only when what it shows has changed.
fn refreshSpotlight() void {
    if (shell.popup != .spotlight) return;
    var open: [MAX_WINDOWS]spotlight.OpenWindow = undefined;
    var n: usize = 0;
    var z = window_count;
    while (z > 0) {
        z -= 1;
        const w = &windows[z_order[z]];
        if (w.panel) continue;
        open[n] = .{ .id = w.id, .title = w.title(), .glyph = desktop.appGlyph(w.app) };
        n += 1;
    }
    shell.query = query_buf[0..query_len];
    const count = spotlight.search(shell.query, open[0..n], spot_files[0..spot_count], &results, &number_buf);
    shell.results = results[0..count];
    if (shell.selected >= count) shell.selected = if (count == 0) 0 else count - 1;
    const rows: usize = if (spotlight.trim(shell.query).len == 0) 0 else @max(count, 1);
    var key: u64 = 0xcbf29ce484222325;
    for (shell.query) |c| key = (key ^ c) *% 0x100000001b3;
    for (shell.results) |r| {
        key = (key ^ @intFromPtr(r.title.ptr)) *% 0x100000001b3;
        key = (key ^ r.title.len) *% 0x100000001b3;
        for (r.title) |c| key = (key ^ c) *% 0x100000001b3;
    }
    key = (key ^ shell.selected) *% 0x100000001b3;
    if (rows == shown_rows and key == shown_key) return;
    addDamage(desktop.popupExtent(&screen, .spotlight));
    desktop.setSpotlightRows(rows);
    addDamage(desktop.popupExtent(&screen, .spotlight));
    shown_rows = rows;
    shown_key = key;
}

fn resetSpotlight() void {
    desktop.setSpotlightRows(0);
    shown_rows = 0;
    shown_key = 0;
}

fn runResult(r: spotlight.Result) void {
    pulp.print("desktop: spotlight runs \"{s}\"\n", .{r.title});
    switch (r.target) {
        .none => shell.popup = .spotlight, // a sum stays on screen
        .app => |app| launchApp(app, false),
        .action => |action| shellAction(action),
        .window => |id| if (findWindowById(id)) |wi| focusWindow(wi),
        .file => |i| if (i < spot_count) openDocument(spot_paths[i][0..spot_path_len[i]]),
    }
}

/// Keys while Spotlight is open: it owns them all.
fn spotlightKey(e: *const pulp.InputEvent) void {
    if (!e.isPress() or isModifier(e.code)) return;
    switch (e.code) {
        keymap.ESC => shellAction(desktop.Action.dismiss),
        keymap.ENTER => if (shell.results.len > 0) shellAction(desktop.Action.result + @as(u16, @intCast(shell.selected))),
        keymap.BACKSPACE => query_len -|= 1,
        0x48 => shell.selected -|= 1, // Up
        0x50, keymap.TAB => if (shell.results.len > 0) {
            shell.selected = if (e.code == keymap.TAB and shell.selected + 1 == shell.results.len) 0 else @min(shell.selected + 1, shell.results.len - 1);
        },
        else => {
            const c = keymap.translate(e.code, shift_held);
            if (c >= ' ' and c < 0x7F and query_len < query_buf.len) {
                // A new query starts at the best match again.
                query_buf[query_len] = c;
                query_len += 1;
                shell.selected = 0;
            }
        },
    }
    if (e.code == keymap.BACKSPACE) shell.selected = 0;
    refreshSpotlight();
    if (shell.popup == .spotlight) {
        pulp.print("desktop: spotlight \"{s}\" {d} results", .{ shell.query, shell.results.len });
        if (shell.results.len > 0) pulp.print(", selected \"{s}\"", .{shell.results[shell.selected].title});
        pulp.puts("\n");
    }
}

/// Alt+Tab: open the switcher on the window used before this one; each
/// further Tab moves on (Shift+Tab back); releasing Alt switches.
fn switcherStep(backwards: bool) void {
    if (shell.popup != .switcher) {
        var n: usize = 0;
        var z = window_count;
        while (z > 0) {
            z -= 1;
            const w = &windows[z_order[z]];
            if (w.panel) continue;
            switch_items[n] = .{ .id = w.id, .app = w.app, .title = w.title(), .hidden = !w.visible };
            n += 1;
        }
        if (n == 0) return;
        if (shell.popup != .none) shellAction(desktop.Action.dismiss);
        shell.switcher = switch_items[0..n];
        desktop.setSwitcherTiles(n);
        // The front window is first; a visible front window means the
        // useful choice is the next one.
        const front_visible = windows[z_order[window_count - 1]].visible and !windows[z_order[window_count - 1]].panel;
        shell.switch_selected = if (n == 1) 0 else if (backwards) n - 1 else if (front_visible) 1 else 0;
        shell.popup = .switcher;
        addDamage(desktop.popupExtent(&screen, .switcher));
    } else {
        const n = shell.switcher.len;
        shell.switch_selected = if (backwards) (shell.switch_selected + n - 1) % n else (shell.switch_selected + 1) % n;
        addDamage(desktop.popupRect(&screen, .switcher));
    }
    pulp.print("desktop: switcher {d} of {d} \"{s}\"\n", .{ shell.switch_selected + 1, shell.switcher.len, shell.switcher[shell.switch_selected].title });
}

fn switcherFinish() void {
    if (shell.popup != .switcher) return;
    addDamage(desktop.popupExtent(&screen, .switcher));
    shell.popup = .none;
    const chosen = shell.switcher[shell.switch_selected];
    shell.switcher = &.{};
    if (findWindowById(chosen.id)) |wi| {
        focusWindow(wi);
        pulp.print("desktop: switched to \"{s}\"\n", .{windows[wi].title()});
    }
}

/// Modifier releases always reach the focused window, even when the shell
/// keeps the key: a lost release leaves it held there (docs/design/012).
fn isModifier(code: u8) bool {
    return code == keymap.CTRL or code == keymap.LSHIFT or code == keymap.RSHIFT or code == 0x38 or code == 0x5B or code == 0x5C;
}
fn forwardRelease(e: *const pulp.InputEvent) void {
    if (!e.isPress() and isModifier(e.code)) if (activeWindow()) |idx| sendInput(idx, e.kind, e.code, e.value, 0, 0);
}

// ── Preferences on /data (docs/design/014, M1) ─────────────────────────────

const PREFS_DIR = "/data/preferences";
const PREFS_PATH = "/data/preferences/desktop";

fn loadPreferences() void {
    const fd = pulp.open(PREFS_PATH) catch {
        // No file yet is normal; no /data at all means nothing can be kept.
        shell.prefs_kept = if (pulp.open("/data")) |d| blk: {
            pulp.close(d);
            break :blk true;
        } else |_| false;
        pulp.print("desktop: no saved preferences ({s})\n", .{if (shell.prefs_kept) "first start" else "no data disk"});
        return;
    };
    defer pulp.close(fd);
    shell.prefs_kept = true;
    var buf: [256]u8 = undefined;
    const n = pulp.read(@intCast(fd), &buf) catch 0;
    var lines = @import("std").mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (pulp.startsWith(line, "theme=")) {
            const v = @import("std").fmt.parseInt(usize, line[6..], 10) catch continue;
            if (v < desktop.THEME_NAMES.len) shell.palette = v;
        }
        if (pulp.startsWith(line, "reduce_motion=")) reduce_motion = pulp.startsWith(line[14..], "1");
        if (pulp.startsWith(line, "lock_minutes=")) lock_minutes = @min(240, std.fmt.parseInt(u32, line[13..], 10) catch 0);
    }
    pulp.print("desktop: preferences loaded, theme {d} {s}, reduce motion {s}\n", .{ shell.palette, desktop.THEME_NAMES[shell.palette], if (reduce_motion) "on" else "off" });
}

fn savePreferences() void {
    pulp.mkdir(PREFS_DIR) catch {};
    const fd = pulp.openWith(PREFS_PATH, pulp.OPEN_WRITE | pulp.OPEN_CREATE | pulp.OPEN_TRUNCATE) catch {
        shell.prefs_kept = false;
        pulp.puts("desktop: preferences not saved (no data disk)\n");
        return;
    };
    defer pulp.close(fd);
    var buf: [128]u8 = undefined;
    const body = @import("std").fmt.bufPrint(&buf, "# Orange OS desktop preferences\ntheme={d}\nreduce_motion={d}\nlock_minutes={d}\n", .{ shell.palette, @intFromBool(reduce_motion), lock_minutes }) catch return;
    _ = pulp.write(@intCast(fd), body) catch {
        pulp.puts("desktop: preferences not saved (write failed)\n");
        return;
    };
    pulp.fsSync(fd) catch {};
    shell.prefs_kept = true;
    pulp.print("desktop: preferences saved, theme {d}, reduce motion {d}\n", .{ shell.palette, @intFromBool(reduce_motion) });
}

fn handleKey(e: *const pulp.InputEvent) void {
    drag_backdrop_valid = false;
    last_input_ms = pulp.uptimeMs();
    if (lock.active) {
        lockKey(e);
        return;
    }
    if (e.isPress() and e.code == 0x01 and openPanel() != null) {
        dismissPanel();
        return;
    }
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
    // Alt (either one) is tracked for Alt+Tab; it still reaches the window.
    if (e.code == 0x38) alt_held = e.isPress();
    if (e.code == keymap.LSHIFT or e.code == keymap.RSHIFT) shift_held = e.isPress();
    // Releasing Alt picks the highlighted window in the switcher.
    if (e.code == 0x38 and !e.isPress() and shell.popup == .switcher) {
        forwardRelease(e);
        switcherFinish();
        return;
    }
    if (alt_held and e.isPress() and e.code == keymap.TAB and openPanel() == null) {
        switcherStep(shift_held);
        return;
    }
    if (shell.popup == .switcher) {
        if (e.isPress() and (e.code == 0x4B or e.code == 0x4D)) switcherStep(e.code == 0x4B);
        forwardRelease(e);
        return;
    }
    // Alt+Space or the Windows/Command key opens Spotlight (Cmd+Space stays
    // with the Mac running QEMU).
    if (e.isPress() and ((alt_held and e.code == 0x39) or ((e.code == 0x5B or e.code == 0x5C) and e.value & 2 != 0))) {
        if (shell.popup == .spotlight) shellAction(desktop.Action.dismiss) else shellAction(desktop.Action.spotlight);
        return;
    }
    if (shell.popup == .spotlight) {
        forwardRelease(e);
        spotlightKey(e);
        return;
    }
    if (shell.popup != .none) {
        forwardRelease(e);
        return;
    }
    // Everything else goes to the focused window - the top of the z-order.
    // Peel does not interpret keys; it routes them.
    if (activeWindow()) |idx| sendInput(idx, e.kind, e.code, e.value, 0, 0);
}

var alt_held: bool = false;

/// The wheel scrolls the client window under the pointer, as on other
/// desktops: the steps travel in the event's code as a signed byte.
fn handleWheel(e: *const pulp.InputEvent) void {
    last_input_ms = pulp.uptimeMs();
    if (lock.active) return;
    const idx = clientWindowAt(cursor_x, cursor_y) orelse return;
    const steps: i8 = @intCast(@max(-127, @min(127, e.dy)));
    sendInput(idx, pulp.EV_WHEEL, @bitCast(steps), 0, cursor_x, cursor_y);
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

    // Publish the port before building the wallpapers: Seed starts apps in
    // parallel and they must be able to queue their window requests now.
    // Three native-resolution caches cost 48 MiB at 2560x1600, within the
    // 3 GiB desktop baseline. A failed allocation uses the procedural path.
    // Build once at startup so a theme click never stalls input for a render.
    for (0..wallpapers.len) |i| {
        loadWallpaperSource(i);
        if (pulp.shmCreate("", back_bytes)) |h| {
            if (pulp.shmMap(h, true)) |pixels| {
                wallpapers[i] = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = screen.width, .height = screen.height, .stride = screen.stride, .scale = screen.scale };
                buildWallpaper(i);
            } else |_| pulp.handleClose(h);
        } else |_| {}
    }

    // Optional, one-time storage; allocation failure preserves normal drawing.
    if (pulp.shmCreate("", back_bytes)) |h| {
        if (pulp.shmMap(h, true)) |pixels| {
            drag_backdrop = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = screen.width, .height = screen.height, .stride = screen.stride, .scale = screen.scale };
        } else |_| {
            pulp.handleClose(h);
        }
    } else |_| {}

    if (pulp.shmCreate("", back_bytes)) |h| {
        if (pulp.shmMap(h, true)) |pixels| {
            anim_scratch = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = screen.width, .height = screen.height, .stride = screen.stride, .scale = screen.scale };
        } else |_| pulp.handleClose(h);
    } else |_| {}

    loadPreferences();
    // An account on the data disk means the session starts locked: the
    // lock screen is the login window.
    loadAccount();
    last_input_ms = pulp.uptimeMs();
    if (account != null) {
        lock = .{ .active = true };
        pulp.puts("desktop: locked (start-up)\n");
    }

    // First frame: everything.
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    composite(full);
    present(full);
    drawCursor(&front, cursor_x, cursor_y);
    presented_cursor_x = cursor_x;
    presented_cursor_y = cursor_y;
    clearDamage();

    var events: [64]pulp.InputEvent = undefined;
    var last_host_poll: u64 = 0;
    while (true) {
        const host_now = pulp.uptimeMs();
        if (host_now -| last_host_poll >= 1000) {
            last_host_poll = host_now;
            const result = pulp.syscall3(111, 0, @intFromPtr(&host_json), host_json.len);
            const host = host_model.parse(host_json[0..if (result > 0) @intCast(result) else 0], &host_scratch);
            // Real hardware driving the desktop: warn once when the Mac's
            // battery runs low on battery power, and again after a recharge.
            if (host.connection == .fresh and host.rows[4].reading == .percent) {
                const percent = host.rows[4].reading.percent;
                const on_power = host.rows[4].power == true;
                if (percent <= 20 and !on_power and !battery_warned) {
                    battery_warned = true;
                    var text: [64]u8 = undefined;
                    postNote("Battery Low", std.fmt.bufPrint(&text, "{d}% left. Connect your Mac to power.", .{percent}) catch "", proto.App.controls);
                } else if (percent > 25 or on_power) battery_warned = false;
            }
            if (!shell.host.eql(host)) {
                shell.host = host;
                addDamage(.{ .x = screen.width - 480, .y = 0, .w = 180, .h = desktop.BAR_H });
                if (pulp.desktop_profile) pulp.print("desktop: host indicators {s}\n", .{@tagName(host.connection)});
            }
        }
        const seconds = pulp.wallTime();
        if (seconds != shell.seconds) {
            if (shell.seconds == null and seconds != null) pulp.print("desktop: wall clock UTC {d}, offset {d} minutes\n", .{ seconds.?, pulp.timezone_minutes });
            if (shell.popup == .calendar and (seconds == null or shell.seconds == null or seconds.? / 60 != shell.seconds.? / 60))
                calendar_damage.add(desktop.popupRect(&screen, .calendar));
            const minute_changed = seconds == null or shell.seconds == null or seconds.? / 60 != shell.seconds.? / 60;
            shell.seconds = seconds;
            addDamage(.{ .x = screen.width - 330, .y = 0, .w = 330, .h = desktop.BAR_H });
            // The lock screen's clock shows minutes.
            if (lock.active and minute_changed) addDamage(.{ .x = 0, .y = 0, .w = screen.width, .h = @divTrunc(screen.height, 2) });
        }

        frame_now = pulp.uptimeMs();
        const n = pulp.inputRead(&events);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = &events[i];
            switch (e.kind) {
                pulp.EV_MOUSE => handleMouse(e),
                pulp.EV_KEY => handleKey(e),
                pulp.EV_WHEEL => handleWheel(e),
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
        refreshSpotlight();
        const animating = tickAnimations();
        // A banner appears with its notification and leaves on its own.
        const banner_now = !lock.active and note_store.banner(pulp.uptimeMs()) != null;
        if (banner_now != banner_shown) {
            banner_shown = banner_now;
            addDamage(gfx.shadowExtent(desktop.bannerRect(&screen)));
        }
        // Lock after the chosen time without keys or pointer movement.
        if (!lock.active and account != null and lock_minutes > 0 and pulp.uptimeMs() -| last_input_ms >= @as(u64, lock_minutes) * 60_000)
            lockScreen("no input");

        // If a base is unavailable (e.g. unusual display bounds), use the
        // ordinary full-glass path. Never restore an uninitialized snapshot.
        if (overview_damage.count != 0 and shell.popup == .overview and !desktop.overviewValid()) addDamage(desktop.popupRect(&screen, .overview));

        if (!calendar_opening and calendar_damage.count != 0 and shell.popup == .calendar and !desktop.calendarValid()) addDamage(desktop.popupRect(&screen, .calendar));
        if (damage.count != 0 or overview_damage.count != 0 or calendar_damage.count != 0 or calendar_opening or cursor_dirty) {
            const started = if (pulp.desktop_profile) pulp.uptimeMs() else 0;
            var repainted_area: i32 = 0;
            if (damage.count != 0) {
                // Expand/merge glass dependencies to a fixed point BEFORE
                // drawing. Overlapping regions are then rendered only once.
                var resolved = damage;
                const retained_calendar = shell.popup == .calendar and desktop.calendarUnderlayValid() and !calendar_opening;
                while (true) {
                    var next: gfx.Damage = .{};
                    var grew = false;
                    for (resolved.rects[0..resolved.count]) |r| {
                        const expanded = expandedDamage(r, retained_calendar);
                        grew = grew or expanded.x != r.x or expanded.y != r.y or expanded.w != r.w or expanded.h != r.h;
                        next.add(expanded);
                    }
                    const stable = !grew and next.count == resolved.count;
                    resolved = next;
                    if (stable) break;
                }
                const panel_extent = desktop.popupExtent(&screen, .calendar);
                calendar_rebuilding = false;
                if (retained_calendar) for (resolved.rects[0..resolved.count]) |r| {
                    if (Rect.overlaps(r, panel_extent)) {
                        calendar_rebuilding = true;
                        break;
                    }
                };
                if (calendar_rebuilding) {
                    screen.resetClip();
                    _ = desktop.restoreCalendarUnderlay(&screen);
                }
                for (resolved.rects[0..resolved.count]) |r| {
                    composite(r);
                    repainted_area += r.w * r.h;
                }
                if (calendar_rebuilding) {
                    screen.setClip(panel_extent);
                    desktop.captureCalendarUnderlay(&screen);
                    var changed = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
                    for (resolved.rects[0..resolved.count]) |r| changed = Rect.unionWith(changed, Rect.intersect(r, panel_extent));
                    desktop.calendarSourceDamage(changed);
                    desktop.paint(&screen, &shell);
                    desktop.calendarSourceDamage(null);
                    screen.resetClip();
                    calendar_rebuilding = false;
                    repainted_area += panel_extent.w * panel_extent.h;
                    // Publish only finished calendar pixels, not its restored
                    // underlay. Raw damage may lie partly outside this panel.
                    present(panel_extent);
                }
                // Publish only after all scene rectangles are complete.
                for (resolved.rects[0..resolved.count]) |r| present(r);
            }
            if (shell.popup == .calendar) {
                if (calendar_opening) {
                    const r = desktop.popupExtent(&screen, .calendar);
                    screen.setClip(r);
                    desktop.captureCalendarUnderlay(&screen);
                    desktop.paint(&screen, &shell);
                    present(r);
                    // Calendar's selected date label is outside the panel.
                    screen.setClip(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
                    // Reconstruct the bar; never blur its already-painted text.
                    calendar_opening = false;
                    composite(screen.clip);
                    present(.{ .x = 0, .y = 0, .w = screen.width, .h = desktop.BAR_H });
                    repainted_area += r.w * r.h;
                }
                for (calendar_damage.rects[0..calendar_damage.count]) |r| {
                    screen.setClip(r);
                    if (desktop.paintCalendarUpdate(&screen, &shell)) {
                        present(r);
                        repainted_area += r.w * r.h;
                    }
                }
                screen.resetClip();
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
        // Input still waiting for a client's port: retry soon.
        var backlogged = false;
        for (windows[0..window_count]) |*w| {
            flushInput(w);
            backlogged = backlogged or w.backlog_len > 0;
        }
        const until_banner = if (banner_shown) note_store.banner_until -| pulp.uptimeMs() + 1 else 1000;
        pulp.waitInput(if (animating) 12 else if (backlogged) 5 else @min(until_banner, 1000 - pulp.uptimeMs() % 1000));
    }
}
