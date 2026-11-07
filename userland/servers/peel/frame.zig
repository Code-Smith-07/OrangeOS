//! Window frame geometry (docs/design/014, M2): the measured title bar and
//! window buttons, resize edges, tiling to half the screen, and the short
//! open and minimise motion. Pure arithmetic, so all of it is unit tested
//! (`zig test userland/servers/peel/frame.zig`); Peel's main loop only
//! applies the results.
const std = @import("std");
const Rect = @import("gfx").Rect;

/// macOS 15, measured from AppKit: a title-only bar is 28 points, a window
/// whose toolbar holds the window buttons is 52.
pub const TITLE_H: i32 = 28;
pub const TOOLBAR_H: i32 = 52;
pub const BORDER: i32 = 1;
/// Window buttons: 12-point circles in 14-point frames, 20 points apart; the
/// first frame starts 7 points in (title bar) or 19 (toolbar windows).
pub const BUTTON_D: i32 = 12;
pub const BUTTON_FRAME: i32 = 14;
pub const BUTTON_PITCH: i32 = 20;
pub const BUTTON_X_TITLE: i32 = 7;
pub const BUTTON_X_TOOLBAR: i32 = 19;
/// Corner radius: about 10 for title-bar windows; toolbar windows are
/// rounder (13 here, which also matches the shadow's corner masks).
pub const RADIUS_TITLE: i32 = 10;
pub const RADIUS_TOOLBAR: i32 = 13;
/// How far outside and inside the frame an edge can be grabbed, and how long
/// a corner grab is along each side.
pub const GRAB_OUT: i32 = 5;
pub const GRAB_IN: i32 = 3;
pub const CORNER: i32 = 14;
/// Open and minimise take 150 ms; Reduce Motion skips them.
pub const MOTION_MS: u64 = 150;
/// Two presses on the title bar this close together zoom the window.
pub const DOUBLE_CLICK_MS: u64 = 450;
pub const DOUBLE_CLICK_SLOP: i32 = 4;

pub const Style = struct {
    /// The client draws under the title area (Files, the browser); Peel draws
    /// only the window buttons, centred in `bar_h`.
    full_size: bool = false,
    bar_h: i32 = TITLE_H,

    pub fn radius(self: Style) i32 {
        return if (self.full_size) RADIUS_TOOLBAR else RADIUS_TITLE;
    }
    /// Where the client's pixels sit inside the frame.
    pub fn content(self: Style, f: Rect) Rect {
        const top = if (self.full_size) 0 else TITLE_H;
        return .{ .x = f.x + BORDER, .y = f.y + top, .w = f.w - BORDER * 2, .h = f.h - top - BORDER };
    }
    /// The frame that holds content of this size.
    pub fn frameSize(self: Style, content_w: i32, content_h: i32) [2]i32 {
        const top = if (self.full_size) 0 else TITLE_H;
        return .{ content_w + BORDER * 2, content_h + top + BORDER };
    }
    /// Window button `index` (close, minimise, zoom), as its 14x16 frame.
    pub fn button(self: Style, f: Rect, index: i32) Rect {
        const first = if (self.full_size) BUTTON_X_TOOLBAR else BUTTON_X_TITLE;
        const bar = if (self.full_size) self.bar_h else TITLE_H;
        return .{ .x = f.x + first + index * BUTTON_PITCH, .y = f.y + @divTrunc(bar - 16, 2), .w = BUTTON_FRAME, .h = 16 };
    }
    /// The three buttons and the gaps between them, for hover.
    pub fn buttonGroup(self: Style, f: Rect) Rect {
        const a = self.button(f, 0);
        return .{ .x = a.x, .y = a.y, .w = BUTTON_PITCH * 2 + BUTTON_FRAME, .h = a.h };
    }
};

pub const Edges = packed struct(u4) {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,

    pub fn any(self: Edges) bool {
        return @as(u4, @bitCast(self)) != 0;
    }
    pub fn diagonal(self: Edges) bool {
        return (self.left or self.right) and (self.top or self.bottom);
    }
};

/// Which edges a press at (x, y) grabs: a thin band outside the frame and a
/// thinner one inside it, with longer corner zones so corners are easy to
/// hit. Nothing when the point is well inside or well outside.
pub fn edgeAt(f: Rect, x: i32, y: i32) Edges {
    const outer = Rect{ .x = f.x - GRAB_OUT, .y = f.y - GRAB_OUT, .w = f.w + GRAB_OUT * 2, .h = f.h + GRAB_OUT * 2 };
    if (!outer.contains(x, y)) return .{};
    const inner = Rect{ .x = f.x + GRAB_IN, .y = f.y + GRAB_IN, .w = f.w - GRAB_IN * 2, .h = f.h - GRAB_IN * 2 };
    if (inner.contains(x, y)) return .{};
    var e = Edges{
        .left = x < f.x + GRAB_IN,
        .right = x >= f.right() - GRAB_IN,
        .top = y < f.y + GRAB_IN,
        .bottom = y >= f.bottom() - GRAB_IN,
    };
    // Near a corner on one side, take both.
    if (e.left or e.right) {
        if (y < f.y + CORNER) e.top = true;
        if (y >= f.bottom() - CORNER) e.bottom = true;
    }
    if (e.top or e.bottom) {
        if (x < f.x + CORNER) e.left = true;
        if (x >= f.right() - CORNER) e.right = true;
    }
    return e;
}

pub const Limits = struct { min_w: i32, min_h: i32, max_w: i32, max_h: i32 };

/// The frame after dragging `edges` of `start` by (dx, dy), within the size
/// limits; the edges not dragged stay where they were.
pub fn resized(start: Rect, edges: Edges, dx: i32, dy: i32, limits: Limits) Rect {
    var w = start.w;
    var h = start.h;
    if (edges.right) w += dx;
    if (edges.left) w -= dx;
    if (edges.bottom) h += dy;
    if (edges.top) h -= dy;
    w = std.math.clamp(w, limits.min_w, @max(limits.min_w, limits.max_w));
    h = std.math.clamp(h, limits.min_h, @max(limits.min_h, limits.max_h));
    return .{
        .x = if (edges.left) start.right() - w else start.x,
        .y = if (edges.top) start.bottom() - h else start.y,
        .w = w,
        .h = h,
    };
}

/// Place a frame of the size the client actually drew (w, h), keeping the
/// edges opposite the ones being dragged fixed.
pub fn anchored(wanted: Rect, edges: Edges, w: i32, h: i32) Rect {
    return .{
        .x = if (edges.left) wanted.right() - w else wanted.x,
        .y = if (edges.top) wanted.bottom() - h else wanted.y,
        .w = w,
        .h = h,
    };
}

pub const Tile = enum { none, left, right, fill };

/// Dragging a window with the pointer at a screen edge offers a tile: the
/// left or right half, or the whole work area at the top (the menu bar).
pub fn tileAt(screen_w: i32, bar_h: i32, x: i32, y: i32) Tile {
    if (x <= 1) return .left;
    if (x >= screen_w - 2) return .right;
    if (y <= bar_h - 1) return .fill;
    return .none;
}

/// The area a tile covers, with the macOS 15 gap between tiles and edges.
pub const TILE_GAP: i32 = 8;
pub fn tileRect(work: Rect, tile: Tile) Rect {
    const g = TILE_GAP;
    const half = @divTrunc(work.w - g * 3, 2);
    return switch (tile) {
        .none => work,
        .fill => .{ .x = work.x + g, .y = work.y + g, .w = work.w - g * 2, .h = work.h - g * 2 },
        .left => .{ .x = work.x + g, .y = work.y + g, .w = half, .h = work.h - g * 2 },
        .right => .{ .x = work.right() - g - half, .y = work.y + g, .w = half, .h = work.h - g * 2 },
    };
}

/// Ease-out cubic over 0..1000 (per mille), so motion starts fast and lands
/// softly. Integer only: Peel has no floating-point state to save.
pub fn easeOut(t_milli: i32) i32 {
    const t = std.math.clamp(t_milli, 0, 1000);
    const u = 1000 - t;
    return 1000 - @divTrunc(u * u * u, 1000 * 1000);
}

pub fn lerpRect(a: Rect, b: Rect, t_milli: i32) Rect {
    const t = std.math.clamp(t_milli, 0, 1000);
    const mix = struct {
        fn f(p: i32, q: i32, k: i32) i32 {
            return p + @divTrunc((q - p) * k, 1000);
        }
    }.f;
    return .{ .x = mix(a.x, b.x, t), .y = mix(a.y, b.y, t), .w = @max(1, mix(a.w, b.w, t)), .h = @max(1, mix(a.h, b.h, t)) };
}

/// A window opening grows from 92% of its size around its centre.
pub fn openFrom(final: Rect) Rect {
    const w = @divTrunc(final.w * 92, 100);
    const h = @divTrunc(final.h * 92, 100);
    return .{ .x = final.x + @divTrunc(final.w - w, 2), .y = final.y + @divTrunc(final.h - h, 2), .w = w, .h = h };
}

/// Second press of a double click: soon enough and close enough.
pub fn isDoubleClick(prev_ms: ?u64, prev_x: i32, prev_y: i32, now: u64, x: i32, y: i32) bool {
    const p = prev_ms orelse return false;
    return now -| p <= DOUBLE_CLICK_MS and @abs(x - prev_x) <= DOUBLE_CLICK_SLOP and @abs(y - prev_y) <= DOUBLE_CLICK_SLOP;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const F = Rect{ .x = 100, .y = 80, .w = 400, .h = 300 };

test "window buttons match the measured macOS geometry" {
    const plain = Style{};
    // 12-point circles centred in 14-point frames: centres 14, 34, 54 from
    // the left in a title bar, 26, 46, 66 in a toolbar window.
    for (0..3) |i| {
        const b = plain.button(F, @intCast(i));
        try testing.expectEqual(F.x + 14 + @as(i32, @intCast(i)) * 20, b.x + @divTrunc(b.w, 2));
        try testing.expectEqual(F.y + 14, b.y + @divTrunc(b.h, 2));
    }
    const toolbar = Style{ .full_size = true, .bar_h = TOOLBAR_H };
    const b = toolbar.button(F, 0);
    try testing.expectEqual(F.x + 26, b.x + @divTrunc(b.w, 2));
    try testing.expectEqual(F.y + 26, b.y + @divTrunc(b.h, 2));
    try testing.expectEqual(@as(i32, 54), toolbar.buttonGroup(F).w);
}

test "content and frame sizes are inverse" {
    for ([_]Style{ .{}, .{ .full_size = true, .bar_h = 36 } }) |s| {
        const c = s.content(F);
        const size = s.frameSize(c.w, c.h);
        try testing.expectEqual(F.w, size[0]);
        try testing.expectEqual(F.h, size[1]);
        try testing.expectEqual(F.bottom() - BORDER, c.bottom());
    }
    try testing.expectEqual(F.y + TITLE_H, (Style{}).content(F).y);
    try testing.expectEqual(F.y, (Style{ .full_size = true }).content(F).y);
}

test "edges are grabbed just outside and inside, corners take both" {
    try testing.expect(!edgeAt(F, 300, 200).any());
    try testing.expect(!edgeAt(F, F.x - GRAB_OUT - 1, 200).any());
    try testing.expectEqual(Edges{ .left = true }, edgeAt(F, F.x - 3, 200));
    try testing.expectEqual(Edges{ .left = true }, edgeAt(F, F.x + 2, 200));
    try testing.expect(!edgeAt(F, F.x + GRAB_IN, 200).any());
    try testing.expectEqual(Edges{ .right = true }, edgeAt(F, F.right() + 2, 200));
    try testing.expectEqual(Edges{ .bottom = true }, edgeAt(F, 300, F.bottom()));
    try testing.expectEqual(Edges{ .top = true }, edgeAt(F, 300, F.y - 1));
    try testing.expectEqual(Edges{ .right = true, .bottom = true }, edgeAt(F, F.right() + 1, F.bottom() - 6));
    try testing.expectEqual(Edges{ .left = true, .top = true }, edgeAt(F, F.x + 6, F.y - 2));
    try testing.expect(edgeAt(F, F.right() + 1, F.bottom() + 1).diagonal());
}

test "resizing keeps the opposite edges and respects the limits" {
    const limits = Limits{ .min_w = 300, .min_h = 200, .max_w = 900, .max_h = 600 };
    const grown = resized(F, .{ .right = true, .bottom = true }, 120, 50, limits);
    try testing.expectEqual(Rect{ .x = 100, .y = 80, .w = 520, .h = 350 }, grown);
    const left = resized(F, .{ .left = true }, 60, 0, limits);
    try testing.expectEqual(F.right(), left.right());
    try testing.expectEqual(@as(i32, 340), left.w);
    // Shrinking stops at the minimum, and the right edge still does not move.
    const tiny = resized(F, .{ .left = true, .top = true }, 500, 500, limits);
    try testing.expectEqual(Rect{ .x = F.right() - 300, .y = F.bottom() - 200, .w = 300, .h = 200 }, tiny);
    const huge = resized(F, .{ .right = true }, 5000, 0, limits);
    try testing.expectEqual(@as(i32, 900), huge.w);
    // A client that drew a different size is placed against the fixed edges.
    const placed = anchored(left, .{ .left = true }, 350, 300);
    try testing.expectEqual(F.right(), placed.right());
}

test "tiles split the work area with even gaps" {
    const work = Rect{ .x = 0, .y = 24, .w = 1280, .h = 776 };
    const l = tileRect(work, .left);
    const r = tileRect(work, .right);
    try testing.expectEqual(TILE_GAP, l.x);
    try testing.expectEqual(work.right() - TILE_GAP, r.right());
    try testing.expectEqual(l.w, r.w);
    try testing.expect(r.x - l.right() >= TILE_GAP);
    try testing.expectEqual(Tile.left, tileAt(1280, 24, 0, 400));
    try testing.expectEqual(Tile.right, tileAt(1280, 24, 1279, 400));
    try testing.expectEqual(Tile.fill, tileAt(1280, 24, 640, 3));
    try testing.expectEqual(Tile.none, tileAt(1280, 24, 640, 400));
}

test "motion eases out and ends exactly on the target" {
    try testing.expectEqual(@as(i32, 0), easeOut(0));
    try testing.expectEqual(@as(i32, 1000), easeOut(1000));
    try testing.expectEqual(@as(i32, 1000), easeOut(4000));
    // Ease-out: more than half the way at the half-way time.
    try testing.expect(easeOut(500) > 800);
    var last: i32 = -1;
    var t: i32 = 0;
    while (t <= 1000) : (t += 50) {
        try testing.expect(easeOut(t) >= last);
        last = easeOut(t);
    }
    const start = openFrom(F);
    try testing.expect(start.w < F.w and start.h < F.h);
    try testing.expect(@abs((start.x * 2 + start.w) - (F.x * 2 + F.w)) <= 1);
    try testing.expectEqual(F, lerpRect(start, F, 1000));
    try testing.expectEqual(start, lerpRect(start, F, 0));
}

test "double clicks need speed and a steady pointer" {
    try testing.expect(!isDoubleClick(null, 0, 0, 100, 0, 0));
    try testing.expect(isDoubleClick(1000, 50, 50, 1300, 52, 49));
    try testing.expect(!isDoubleClick(1000, 50, 50, 1600, 50, 50));
    try testing.expect(!isDoubleClick(1000, 50, 50, 1100, 60, 50));
}
