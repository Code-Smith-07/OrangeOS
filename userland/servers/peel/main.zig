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
const gfx = @import("gfx.zig");
const font = @import("font.zig");

const Rect = gfx.Rect;
const Color = gfx.Color;

// ── Theme ───────────────────────────────────────────────────────────────────

const ORANGE: Color = 0xFF8C1A;
const ORANGE_DEEP: Color = 0xC25E00;
const BG_TOP: Color = 0x1A1410;
const BG_BOTTOM: Color = 0x0C0906;
const WIN_BG: Color = 0x1E1A17;
const WIN_TITLE: Color = 0x2A2420;
const WIN_TITLE_ACTIVE: Color = 0x3A2A18;
const TEXT: Color = 0xEAE0D5;
const TEXT_DIM: Color = 0x8A7A6A;
const BORDER: Color = 0x000000;

const TITLE_H: i32 = 26;
const BORDER_W: i32 = 1;
const SHADOW: i32 = 6;

// ── Windows ─────────────────────────────────────────────────────────────────

const MAX_WINDOWS = 8;

const Window = struct {
    rect: Rect,
    title_buf: [48]u8 = undefined,
    title_len: usize = 0,
    accent: Color,
    visible: bool = true,

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
        return .{ .x = self.rect.right() - 28, .y = self.rect.y, .w = 28, .h = TITLE_H };
    }

    /// The area the compositor must repaint for this window: its frame plus
    /// the shadow that falls outside it.
    fn damageRect(self: *const Window) Rect {
        return .{
            .x = self.rect.x - 1,
            .y = self.rect.y - 1,
            .w = self.rect.w + SHADOW + 2,
            .h = self.rect.h + SHADOW + 2,
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
    windows[idx] = .{ .rect = r, .accent = accent, .id = next_window_id };
    windows[idx].setTitle(title);
    next_window_id += 1;
    z_order[idx] = idx;
    window_count += 1;
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
    if (window_count == 0 or z_order[window_count - 1] == index) return;
    const previous = z_order[window_count - 1];
    addDamage(windows[previous].damageRect());
    raise(index);
    addDamage(windows[index].damageRect());
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

var damage: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

fn addDamage(r: Rect) void {
    damage = Rect.unionWith(damage, r);
}

fn clearDamage() void {
    damage = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

// ── Cursor ──────────────────────────────────────────────────────────────────

const CURSOR_W: i32 = 10;
const CURSOR_H: i32 = 16;

var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var prev_cursor_x: i32 = 0;
var prev_cursor_y: i32 = 0;

fn cursorRect(x: i32, y: i32) Rect {
    return .{ .x = x, .y = y, .w = CURSOR_W, .h = CURSOR_H };
}

/// A simple arrow: each row is a run starting at the left edge.
fn drawCursor(s: *const gfx.Surface, x: i32, y: i32) void {
    const widths = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 6, 4, 4, 3, 2, 1, 0 };
    var row: i32 = 0;
    while (row < CURSOR_H) : (row += 1) {
        const w = widths[@intCast(row)];
        if (w == 0) continue;
        // Black outline first, white fill inside it, so the pointer stays
        // visible over both light and dark content.
        s.fill(.{ .x = x, .y = y + row, .w = w + 1, .h = 1 }, 0x000000);
        s.fill(.{ .x = x + 1, .y = y + row, .w = w - 1, .h = 1 }, 0xFFFFFF);
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

fn paintWallpaper(clip: Rect) void {
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    const area = Rect.intersect(clip, full);
    if (area.isEmpty()) return;

    // Gradient computed per row against the full screen height, then clipped,
    // so a partial repaint matches what a full one would have produced.
    var y = area.y;
    while (y < area.bottom()) : (y += 1) {
        const t: u32 = @intCast(@divTrunc(y * 255, @max(screen.height, 1)));
        const c = gfx.lerp(BG_TOP, BG_BOTTOM, @intCast(t));
        screen.fill(.{ .x = area.x, .y = y, .w = area.w, .h = 1 }, c);
    }
}

fn paintWindow(w: *const Window, active: bool, clip: Rect) void {
    if (!w.visible) return;
    if (!Rect.overlaps(w.damageRect(), clip)) return;

    // Shadow: offset down-right, darkening whatever is beneath. Only the
    // fringe outside the window is visible, since the background fill below
    // covers the rest - and shading is applied to freshly painted wallpaper
    // each frame, so it does not accumulate.
    screen.shade(.{
        .x = w.rect.x + SHADOW,
        .y = w.rect.y + SHADOW,
        .w = w.rect.w,
        .h = w.rect.h,
    }, 120);

    screen.fill(w.rect, WIN_BG);
    screen.fill(w.titleBar(), if (active) WIN_TITLE_ACTIVE else WIN_TITLE);
    screen.outline(w.rect, BORDER, BORDER_W);

    // Accent stripe along the top of the title bar.
    screen.fill(.{ .x = w.rect.x, .y = w.rect.y, .w = w.rect.w, .h = 2 }, w.accent);

    font.drawText(&screen, w.title(), w.rect.x + 10, w.rect.y + 9, 1, if (active) TEXT else TEXT_DIM);

    if (w.closable) {
        font.drawChar(&screen, 'x', w.rect.right() - 18, w.rect.y + 9, 1, TEXT_DIM);
    }

    // Client content: copy the client's buffer into place. Peel never draws
    // inside a client window, and the client never touches the screen.
    if (w.pixels) |src| {
        const content = w.contentRect();
        const area = Rect.intersect(content, clip);
        if (!area.isEmpty()) {
            var y = area.y;
            while (y < area.bottom()) : (y += 1) {
                const sy = y - content.y;
                if (sy < 0 or sy >= w.client_h) continue;
                var x = area.x;
                while (x < area.right()) : (x += 1) {
                    const sx = x - content.x;
                    if (sx < 0 or sx >= w.client_w) continue;
                    screen.put(x, y, src[@intCast(sy * w.client_w + sx)]);
                }
            }
        }
    } else {
        font.drawText(&screen, "waiting for a client...", w.rect.x + 12, w.rect.y + TITLE_H + 14, 1, TEXT_DIM);
    }
}

fn paintPanel(clip: Rect) void {
    const panel = Rect{ .x = 0, .y = 0, .w = screen.width, .h = 22 };
    if (!Rect.overlaps(panel, clip)) return;

    screen.fill(panel, 0x14100C);
    screen.fill(.{ .x = 0, .y = 22, .w = screen.width, .h = 1 }, ORANGE_DEEP);
    font.drawText(&screen, "Orange OS", 10, 7, 1, ORANGE);
    font.drawText(&screen, "Peel compositor", 100, 7, 1, TEXT_DIM);
}

/// Repaint everything intersecting `area`, back to front.
fn composite(area: Rect) void {
    const clip = Rect.intersect(area, .{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
    if (clip.isEmpty()) return;

    // Everything drawn this frame is confined to the damage region. Window
    // backgrounds and title bars are drawn unclipped by intent - they are
    // whole-rectangle fills - so without this a small commit would blank an
    // entire window and repaint only the damaged strip of its contents.
    screen.setClip(clip);
    defer screen.resetClip();

    paintWallpaper(clip);
    paintPanel(clip);

    var i: usize = 0;
    while (i < window_count) : (i += 1) {
        const idx = z_order[i];
        paintWindow(&windows[idx], i == window_count - 1, clip);
    }

    drawCursor(&screen, cursor_x, cursor_y);
}

/// Publish an already-composited rectangle to the visible framebuffer.
fn present(area: Rect) void {
    const clip = Rect.intersect(area, .{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
    if (clip.isEmpty()) return;

    var y = clip.y;
    while (y < clip.bottom()) : (y += 1) {
        const src_row: usize = @intCast(y * screen.stride);
        const dst_row: usize = @intCast(y * front.stride);
        const x: usize = @intCast(clip.x);
        const width: usize = @intCast(clip.w);
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

    const w: i32 = @intCast(req.width);
    const h: i32 = @intCast(req.height);
    if (w <= 0 or h <= 0 or w > 2000 or h > 2000) {
        sendCreated(reply, 0, req.width, req.height);
        pulp.handleClose(reply);
        return;
    }

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
        .{ .x = req.x, .y = req.y, .w = frame_w, .h = frame_h },
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
    if (window_count > 0) addDamage(windows[z_order[window_count - 1]].damageRect());
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
    // Non-blocking: the compositor must keep drawing whether or not a client
    // has anything to say.
    while (true) {
        const m = pulp.portRecvMsg(server_port, &buf, false) catch return;
        if (m.len == 0) return;
        switch (m.opcode) {
            proto.Op.create_window => handleCreateWindow(buf[0..m.len]),
            proto.Op.commit => handleCommit(buf[0..m.len]),
            proto.Op.destroy => handleDestroy(buf[0..m.len]),
            else => {},
        }
    }
}

var dragging: ?u32 = null;
var close_pressed: ?u32 = null;
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
        .x = sx - content.x,
        .y = sy - content.y,
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

    cursor_x += e.dx;
    cursor_y += e.dy;
    cursor_x = @max(0, @min(cursor_x, screen.width - 1));
    cursor_y = @max(0, @min(cursor_y, screen.height - 1));

    const was_down = buttons & 1 != 0;
    const is_down = e.code & 1 != 0;
    buttons = e.code;

    if (is_down and !was_down) {
        if (windowAt(cursor_x, cursor_y)) |idx| {
            focusWindow(idx);
            const id = windows[idx].id;
            if (windows[idx].titleBar().contains(cursor_x, cursor_y)) {
                if (windows[idx].closable and windows[idx].closeButton().contains(cursor_x, cursor_y)) {
                    close_pressed = id;
                } else {
                    dragging = id;
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
        windows[idx].rect.y = @max(23, @min(cursor_y - drag_dy, screen.height - TITLE_H));
        addDamage(windows[idx].damageRect());
    };

    if (!is_down and was_down) {
        if (close_pressed) |id| {
            if (findWindowById(id)) |idx| {
                if (windows[idx].closeButton().contains(cursor_x, cursor_y)) requestClose(id);
            }
        }
        dragging = null;
        close_pressed = null;
    }

    if (dragging == null and close_pressed == null) {
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

    addDamage(cursorRect(prev_cursor_x, prev_cursor_y));
    addDamage(cursorRect(cursor_x, cursor_y));
}

fn handleKey(e: *const pulp.InputEvent) void {
    // Tab cycles focus, so the compositor is demonstrable without a mouse.
    if (e.isPress() and e.code == 0x0F and window_count > 1) {
        const bottom = z_order[0];
        focusWindow(bottom);
        return;
    }

    // Everything else goes to the focused window - the top of the z-order.
    // Peel does not interpret keys; it routes them.
    if (window_count == 0) return;
    sendInput(z_order[window_count - 1], e.kind, e.code, e.value, 0, 0);
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

    front = .{
        .pixels = framebuffer_pixels,
        .width = @intCast(info.width),
        .height = @intCast(info.height),
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
        .stride = front.width,
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

    // First frame: everything.
    const full = Rect{ .x = 0, .y = 0, .w = screen.width, .h = screen.height };
    composite(full);
    present(full);
    clearDamage();

    var events: [32]pulp.InputEvent = undefined;
    while (true) {
        pumpClients();

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

        if (!damage.isEmpty()) {
            composite(damage);
            present(damage);
            clearDamage();
            frames += 1;
        }

        // Sleep until either source has work. input_wait registers before it
        // checks both the input queue and this process's bound client port, so
        // an event landing between this loop and the syscall cannot be lost.
        // No polling timeout is needed: input drivers and portSend both wake
        // the same channel.
        pulp.waitInput(0);
    }
}
