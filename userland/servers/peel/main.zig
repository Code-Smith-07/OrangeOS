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

fn addWindow(r: Rect, title: []const u8, accent: Color) usize {
    if (window_count >= MAX_WINDOWS) return 0;
    const idx = window_count;
    windows[idx] = .{ .rect = r, .accent = accent, .id = next_window_id };
    windows[idx].setTitle(title);
    next_window_id += 1;
    z_order[idx] = idx;
    window_count += 1;
    return idx;
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

var screen: gfx.Surface = undefined;

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

    // Close button.
    font.drawChar(&screen, 'x', w.rect.right() - 18, w.rect.y + 9, 1, TEXT_DIM);

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

// ── Input ───────────────────────────────────────────────────────────────────

var server_port: i64 = -1;

// ── Client protocol ─────────────────────────────────────────────────────────

const ACCENTS = [_]Color{ ORANGE, 0x60A0E0, 0x70C070, 0xD070C0, 0xE0B040 };

fn handleCreateWindow(payload: []const u8) void {
    if (payload.len < @sizeOf(proto.CreateWindow)) return;
    const req: *align(1) const proto.CreateWindow = @ptrCast(payload.ptr);

    const w: i32 = @intCast(req.width);
    const h: i32 = @intCast(req.height);
    if (w <= 0 or h <= 0 or w > 2000 or h > 2000) return;

    const title_len = @min(req.title_len, 48);
    const name_len = @min(req.shm_name_len, 32);

    // Map the client's buffer. Peel takes it read-only in spirit: it copies
    // out of it and never writes back, so a misbehaving client can corrupt
    // its own window and nothing else.
    const shm = pulp.shmOpen(req.shm_name[0..name_len]) catch {
        pulp.puts("peel: client buffer not found\n");
        return;
    };
    const pixels = pulp.shmMap(shm, false) catch {
        pulp.puts("peel: cannot map client buffer\n");
        return;
    };

    const frame_w = w + BORDER_W * 2;
    const frame_h = h + TITLE_H + BORDER_W;
    const idx = addWindow(
        .{ .x = req.x, .y = req.y, .w = frame_w, .h = frame_h },
        req.title[0..title_len],
        ACCENTS[window_count % ACCENTS.len],
    );

    windows[idx].pixels = @ptrCast(@alignCast(pixels));
    windows[idx].client_w = w;
    windows[idx].client_h = h;

    // Answer on the client's own reply port. A shared reply port would deliver
    // one client's answer to whichever client happened to read first.
    var name_buf: [32]u8 = undefined;
    const reply_name = proto.replyPortName(&name_buf, req.pid);
    if (pulp.portConnect(reply_name)) |reply| {
        windows[idx].reply_port = reply;
        const created = proto.Created{
            .window_id = windows[idx].id,
            .width = req.width,
            .height = req.height,
        };
        const bytes: [*]const u8 = @ptrCast(&created);
        _ = pulp.portSend(reply, proto.Op.created, bytes[0..@sizeOf(proto.Created)]) catch {};
    } else |_| {
        pulp.puts("peel: client has no reply port\n");
    }

    pulp.print("peel: window {d} \"{s}\" {d}x{d} for pid {d}\n", .{
        windows[idx].id, windows[idx].title(), w, h, req.pid,
    });

    addDamage(windows[idx].damageRect());
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
            else => {},
        }
    }
}

var dragging: ?usize = null;
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
            raise(idx);
            addDamage(windows[idx].damageRect());
            if (windows[idx].titleBar().contains(cursor_x, cursor_y)) {
                dragging = idx;
                drag_dx = cursor_x - windows[idx].rect.x;
                drag_dy = cursor_y - windows[idx].rect.y;
            }
        }
    } else if (!is_down) {
        dragging = null;
    }

    if (dragging) |idx| {
        // Damage both where the window was and where it is going, or the old
        // position is left painted on screen.
        addDamage(windows[idx].damageRect());
        windows[idx].rect.x = cursor_x - drag_dx;
        windows[idx].rect.y = cursor_y - drag_dy;
        addDamage(windows[idx].damageRect());
    } else if (windowAt(cursor_x, cursor_y)) |idx| {
        // Not dragging: forward pointer activity to whichever window is under
        // the cursor, so its client can hit-test its own widgets. Events over
        // the title bar belong to the compositor and are not forwarded.
        if (!windows[idx].titleBar().contains(cursor_x, cursor_y)) {
            sendInput(idx, pulp.EV_MOUSE, buttons, 0, cursor_x, cursor_y);
        }
    }

    addDamage(cursorRect(prev_cursor_x, prev_cursor_y));
    addDamage(cursorRect(cursor_x, cursor_y));
}

fn handleKey(e: *const pulp.InputEvent) void {
    // Tab cycles focus, so the compositor is demonstrable without a mouse.
    if (e.isPress() and e.code == 0x0F and window_count > 1) {
        const bottom = z_order[0];
        raise(bottom);
        var i: usize = 0;
        while (i < window_count) : (i += 1) addDamage(windows[i].damageRect());
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

    const pixels = pulp.fbMap() catch {
        pulp.puts("peel: cannot map the framebuffer\n");
        pulp.exit(1);
    };

    screen = .{
        .pixels = pixels,
        .width = @intCast(info.width),
        .height = @intCast(info.height),
        .stride = @intCast(info.pitch / 4),
    };

    pulp.print("peel: {d}x{d}, {d} bpp, stride {d}\n", .{
        info.width, info.height, info.bpp, screen.stride,
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
    composite(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
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
