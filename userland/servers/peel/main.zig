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
    title: []const u8,
    body: []const u8,
    accent: Color,
    visible: bool = true,

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

fn addWindow(r: Rect, title: []const u8, body: []const u8, accent: Color) void {
    if (window_count >= MAX_WINDOWS) return;
    windows[window_count] = .{ .rect = r, .title = title, .body = body, .accent = accent };
    z_order[window_count] = window_count;
    window_count += 1;
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

    // Shadow: offset down-right, darkening whatever is beneath.
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

    font.drawText(&screen, w.title, w.rect.x + 10, w.rect.y + 9, 1, if (active) TEXT else TEXT_DIM);

    // Close button.
    const bx = w.rect.right() - 18;
    const by = w.rect.y + 9;
    font.drawChar(&screen, 'x', bx, by, 1, TEXT_DIM);

    font.drawText(&screen, w.body, w.rect.x + 12, w.rect.y + TITLE_H + 14, 1, TEXT_DIM);
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

var dragging: ?usize = null;
var drag_dx: i32 = 0;
var drag_dy: i32 = 0;
var buttons: u8 = 0;
var frames: u64 = 0;

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
    }

    addDamage(cursorRect(prev_cursor_x, prev_cursor_y));
    addDamage(cursorRect(cursor_x, cursor_y));
}

fn handleKey(e: *const pulp.InputEvent) void {
    if (!e.isPress()) return;
    // Tab cycles focus, so the compositor is demonstrable without a mouse.
    if (e.code == 0x0F and window_count > 0) {
        const bottom = z_order[0];
        raise(bottom);
        var i: usize = 0;
        while (i < window_count) : (i += 1) addDamage(windows[i].damageRect());
    }
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

    addWindow(
        .{ .x = 90, .y = 90, .w = 380, .h = 210 },
        "Welcome to Orange OS",
        "Drag me by the title bar.",
        ORANGE,
    );
    addWindow(
        .{ .x = 330, .y = 220, .w = 400, .h = 240 },
        "Peel - compositor",
        "Software composited. No GPU.",
        0x60A0E0,
    );
    addWindow(
        .{ .x = 620, .y = 130, .w = 340, .h = 190 },
        "Zest - kernel",
        "Written from scratch.",
        0x70C070,
    );

    // First frame: everything.
    composite(.{ .x = 0, .y = 0, .w = screen.width, .h = screen.height });
    clearDamage();

    var events: [32]pulp.InputEvent = undefined;
    while (true) {
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

        // Nothing to do until more input arrives. Sleeping rather than
        // spinning is what keeps an idle desktop at nearly zero CPU.
        if (n == 0) pulp.sleepMs(8);
    }
}
