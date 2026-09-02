//! Segment — the Orange OS widget toolkit.
//!
//! A window is a tree of widgets. Segment owns the event loop: it takes input
//! from Peel, hit-tests it against the tree, repaints what changed, and
//! commits. An application describes what it wants on screen and provides
//! callbacks; it never talks to the compositor directly.
//!
//! Widgets are values in a fixed array rather than heap objects. There is no
//! allocator worth the name in userland yet, and a bounded widget count is a
//! reasonable constraint for the applications that exist.

const pulp = @import("pulp");
const libpeel = @import("libpeel");
const glyphs = @import("glyphs.zig");

pub const proto = libpeel.proto;

// ── Theme ───────────────────────────────────────────────────────────────────

pub const Theme = struct {
    bg: u32 = 0x16120F,
    surface: u32 = 0x201B17,
    surface_hover: u32 = 0x2C2520,
    surface_active: u32 = 0x3A2A18,
    accent: u32 = 0xFF8C1A,
    text: u32 = 0xEAE0D5,
    text_dim: u32 = 0x8A7A6A,
    border: u32 = 0x000000,
};

pub var theme: Theme = .{};

// ── Geometry ────────────────────────────────────────────────────────────────

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and
            py >= self.y and py < self.y + self.h;
    }
};

// ── Widgets ─────────────────────────────────────────────────────────────────

pub const Kind = enum { label, button, panel, separator };

pub const Callback = *const fn (id: u32) void;

pub const Widget = struct {
    kind: Kind,
    id: u32 = 0,
    rect: Rect,
    text: []const u8 = "",
    color: u32 = 0,
    scale: i32 = 1,
    on_click: ?Callback = null,

    hovered: bool = false,
    pressed: bool = false,
};

pub const MAX_WIDGETS = 24;

pub const App = struct {
    win: libpeel.Window,
    widgets: [MAX_WIDGETS]Widget = undefined,
    count: usize = 0,
    /// Set when anything visual changed, so the frame loop knows to repaint.
    dirty: bool = true,

    pub fn add(self: *App, w: Widget) u32 {
        if (self.count >= MAX_WIDGETS) return 0;
        var widget = w;
        widget.id = @intCast(self.count + 1);
        self.widgets[self.count] = widget;
        self.count += 1;
        self.dirty = true;
        return widget.id;
    }

    pub fn label(self: *App, text: []const u8, x: i32, y: i32, scale: i32, color: u32) u32 {
        return self.add(.{
            .kind = .label,
            .rect = .{ .x = x, .y = y, .w = textWidth(text, scale), .h = 8 * scale },
            .text = text,
            .color = color,
            .scale = scale,
        });
    }

    pub fn button(self: *App, text: []const u8, x: i32, y: i32, w: i32, h: i32, cb: Callback) u32 {
        return self.add(.{
            .kind = .button,
            .rect = .{ .x = x, .y = y, .w = w, .h = h },
            .text = text,
            .color = theme.text,
            .on_click = cb,
        });
    }

    pub fn panel(self: *App, x: i32, y: i32, w: i32, h: i32, color: u32) u32 {
        return self.add(.{
            .kind = .panel,
            .rect = .{ .x = x, .y = y, .w = w, .h = h },
            .color = color,
        });
    }

    pub fn separator(self: *App, x: i32, y: i32, w: i32) u32 {
        return self.add(.{
            .kind = .separator,
            .rect = .{ .x = x, .y = y, .w = w, .h = 1 },
            .color = theme.text_dim,
        });
    }

    pub fn setText(self: *App, id: u32, text: []const u8) void {
        if (id == 0 or id > self.count) return;
        self.widgets[id - 1].text = text;
        self.dirty = true;
    }

    /// Tell Peel the window is gone, then terminate the application.
    pub fn close(self: *App) noreturn {
        self.win.destroy();
        pulp.exit(0);
    }

    // ── Painting ────────────────────────────────────────────────────────────

    fn drawGlyph(self: *App, c: u8, x: i32, y: i32, scale: i32, color: u32) void {
        const g = glyphs.glyph(c);
        var row: i32 = 0;
        while (row < 8) : (row += 1) {
            const bits = g[@intCast(row)];
            var col: i32 = 0;
            while (col < 8) : (col += 1) {
                if (bits & (@as(u8, 0x80) >> @intCast(col)) == 0) continue;
                self.win.fill(x + col * scale, y + row * scale, scale, scale, color);
            }
        }
    }

    pub fn drawText(self: *App, text: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
        var cx = x;
        for (text) |c| {
            self.drawGlyph(c, cx, y, scale, color);
            cx += 8 * scale;
        }
    }

    fn paintWidget(self: *App, w: *const Widget) void {
        switch (w.kind) {
            .panel => self.win.fill(w.rect.x, w.rect.y, w.rect.w, w.rect.h, w.color),
            .separator => self.win.fill(w.rect.x, w.rect.y, w.rect.w, 1, w.color),
            .label => self.drawText(w.text, w.rect.x, w.rect.y, w.scale, w.color),
            .button => {
                const bg = if (w.pressed)
                    theme.surface_active
                else if (w.hovered)
                    theme.surface_hover
                else
                    theme.surface;

                self.win.fill(w.rect.x, w.rect.y, w.rect.w, w.rect.h, bg);
                // Accent bar on the left, brighter when the pointer is over it.
                self.win.fill(w.rect.x, w.rect.y, 2, w.rect.h, if (w.hovered) theme.accent else theme.text_dim);

                const tw = textWidth(w.text, 1);
                const tx = w.rect.x + @divTrunc(w.rect.w - tw, 2);
                const ty = w.rect.y + @divTrunc(w.rect.h - 8, 2);
                self.drawText(w.text, tx, ty, 1, if (w.hovered) theme.text else theme.text_dim);
            },
        }
    }

    pub fn paint(self: *App) void {
        if (!self.dirty) return;
        self.dirty = false;

        self.win.clear(theme.bg);
        var i: usize = 0;
        while (i < self.count) : (i += 1) self.paintWidget(&self.widgets[i]);
        self.win.commitAll();
    }

    // ── Events ──────────────────────────────────────────────────────────────

    fn handlePointer(self: *App, x: i32, y: i32, buttons: u8) void {
        const down = buttons & 1 != 0;

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const w = &self.widgets[i];
            if (w.kind != .button) continue;

            const over = w.rect.contains(x, y);
            const was_hovered = w.hovered;
            const was_pressed = w.pressed;

            w.hovered = over;
            w.pressed = over and down;

            // Fire on release over the widget, which is what a user expects:
            // pressing and dragging away should cancel.
            if (was_pressed and !down and over) {
                if (w.on_click) |cb| cb(w.id);
            }

            if (w.hovered != was_hovered or w.pressed != was_pressed) self.dirty = true;
        }
    }

    /// Drain input from Peel and dispatch it. Returns true if anything arrived.
    pub fn pumpEvents(self: *App) bool {
        var msg: [128]u8 = undefined;
        var got = false;

        while (true) {
            const m = pulp.portRecvMsg(self.win.reply, &msg, false) catch return got;
            if (m.len == 0) return got;
            if (m.opcode == proto.Op.close_requested) self.close();
            if (m.opcode != proto.Op.input) continue;
            if (m.len < @sizeOf(proto.Input)) continue;

            const ev: *align(1) const proto.Input = @ptrCast(&msg);
            got = true;

            if (ev.kind == pulp.EV_MOUSE) {
                self.handlePointer(ev.x, ev.y, ev.code);
            }
        }
    }

    /// Run until the process exits. Sleeps when idle so a static window costs
    /// essentially no CPU.
    pub fn run(self: *App) noreturn {
        while (true) {
            const busy = self.pumpEvents();
            self.paint();
            if (!busy) pulp.sleepMs(16);
        }
    }
};

pub fn textWidth(text: []const u8, scale: i32) i32 {
    return @as(i32, @intCast(text.len)) * 8 * scale;
}

/// Create a window and an App bound to it.
pub fn createApp(title: []const u8, w: i32, h: i32, x: i32, y: i32) !App {
    const win = try libpeel.createWindow(title, w, h, x, y);
    return .{ .win = win };
}

pub fn createAppWithFlags(title: []const u8, w: i32, h: i32, x: i32, y: i32, flags: u32) !App {
    const win = try libpeel.createWindowWithFlags(title, w, h, x, y, flags);
    return .{ .win = win };
}
