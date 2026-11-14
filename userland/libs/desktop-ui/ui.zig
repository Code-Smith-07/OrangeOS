//! Shared SVG-derived desktop artwork. Rendered at native backing scale.
pub const gfx = @import("gfx");
pub const Surface = gfx.Surface;
pub const Rect = gfx.Rect;
/// Aurora's shared surface/ink palette. Colour is intentional, not a layer of
/// purple tint on every control. Keep readable content more opaque than chrome.
pub const Color = struct {
    pub const canvas: u32 = 0xF7F9FC;
    pub const paper: u32 = 0xFFFFFF;
    pub const ink: u32 = 0x253247;
    pub const muted: u32 = 0x778397;
    pub const line: u32 = 0xE1E7EF;
    pub const accent: u32 = 0x397BE8;
    pub const selection: u32 = 0xE5EEFD;
};
const font = @import("typography");
pub const textWidth = font.textWidth;
pub const Icon = enum { welcome, terminal, clock, about, windows, appearance, files, trash, chevron_left, chevron_right, chevron_up, document, brand, controls, close, minimize, maximize, pointer, folder_orange, folder_green, folder_purple, folder_pink, folder_gold, wifi, bluetooth, speaker, sun, battery, battery_plain, sidebar_home, sidebar_apps, sidebar_system, sidebar_trash, menu_wifi, menu_bluetooth, menu_speaker, menu_controls, menu_battery, menu_battery_plain, menu_brand, dock_welcome, dock_terminal, dock_clock, dock_about, dock_windows, dock_appearance, dock_files, dock_trash, dock_browser, menu_search, search, dock_calculator, app_browser, cursor_resize_h, cursor_resize_v, cursor_resize_nwse, cursor_resize_nesw, dock_editor, dock_viewer, app_editor, app_viewer, app_calculator, menu_bell, sym_folder_plus, sym_pencil, sym_eye, sym_restore, sym_lock, sym_user, sym_image, sym_display, sym_clock, sym_keyboard, sym_info, sym_bell, sym_save, sym_plus, sym_minus, sidebar_documents, image_file };
pub const Button = struct { id: u32, rect: Rect };

/// The shared toolkit (docs/design/014, M2): one set of measured sizes and
/// one way to draw each control, so every app looks like it belongs to the
/// same system. Sizes are macOS 15's, measured from AppKit.
pub const Metrics = struct {
    /// A toolbar window's top bar, which holds the window buttons.
    pub const toolbar_h: i32 = 52;
    /// Room the window buttons need at the left of a toolbar (19 + 54 + gap).
    pub const buttons_w: i32 = 84;
    /// Toolbar items: 28-point square buttons and 28-point segmented controls.
    pub const toolbar_item: i32 = 28;
    /// Push buttons: regular, small, large.
    pub const push_h: i32 = 32;
    pub const push_small_h: i32 = 27;
    pub const push_large_h: i32 = 40;
    /// Text and search fields.
    pub const field_h: i32 = 21;
    pub const search_h: i32 = 22;
    /// Switch, slider, pop-up button.
    pub const switch_w: i32 = 42;
    pub const switch_h: i32 = 25;
    pub const slider_h: i32 = 28;
    pub const popup_h: i32 = 25;
    /// Table and sidebar rows.
    pub const row_h: i32 = 24;
    /// Corner radii: controls, fields, selection.
    pub const control_radius: i32 = 6;
    pub const field_radius: i32 = 6;
    /// Gaps: between toolbar items, and inside content.
    pub const gap: i32 = 8;
    pub const margin: i32 = 16;
};

/// What a control looks like right now.
pub const ControlState = struct {
    hover: bool = false,
    pressed: bool = false,
    selected: bool = false,
    enabled: bool = true,

    /// From the shared pointer tracker, for the control with this id.
    pub fn of(p: Pointer, id: u32) ControlState {
        return .{ .hover = p.hover == id, .pressed = p.pressed == id and p.hover == id };
    }
};

/// Light toolkit colours; one hue (the accent) for selection and focus.
pub const Tone = struct {
    pub const toolbar: u32 = 0xF6F6F8;
    pub const sidebar: u32 = 0xEEEEF1;
    pub const hairline: u32 = 0xDCDDE1;
    pub const hover: u32 = 0xE6E7EA;
    pub const pressed: u32 = 0xD9DADE;
    pub const field: u32 = 0xFFFFFF;
    pub const field_rim: u32 = 0xD5D7DC;
    pub const placeholder: u32 = 0x8D9097;
    pub const text: u32 = 0x2B2E34;
    pub const secondary: u32 = 0x6E727A;
    pub const symbol: u32 = 0x5C6067;
    pub const disabled: u32 = 0xBABDC2;
    pub const accent: u32 = 0x0A7AFF;
    pub const accent_soft: u32 = 0xD9E8FD;
};

/// A borderless toolbar button: a symbol on nothing until hovered, like the
/// Finder's back and forward buttons.
pub fn toolbarButton(s: *const Surface, r: Rect, symbol: Icon, st: ControlState) void {
    const fill: ?u32 = if (!st.enabled) null else if (st.pressed) Tone.pressed else if (st.hover or st.selected) Tone.hover else null;
    if (fill) |c| s.rounded(r, Metrics.control_radius, c, 255);
    const size: i32 = 18;
    iconTint(s, symbol, r.x + @divTrunc(r.w - size, 2), r.y + @divTrunc(r.h - size, 2), size, if (st.enabled) Tone.symbol else Tone.disabled);
}

/// A rounded push button with a centred label; `default` is the accent one.
pub fn pushButton(s: *const Surface, r: Rect, text: []const u8, default: bool, st: ControlState) void {
    if (default) {
        s.rounded(r, Metrics.control_radius, if (st.pressed) gfx.lerp(Tone.accent, 0x000000, 40) else Tone.accent, 255);
        // A faint reflection along the top: light on a glossy surface.
        s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = @divTrunc(r.h, 2) }, Metrics.control_radius - 1, 0xFFFFFF, 26);
    } else {
        s.rounded(r, Metrics.control_radius, Tone.field_rim, 255);
        s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, Metrics.control_radius - 1, if (st.pressed) Tone.pressed else if (st.hover) 0xF7F7F9 else 0xFFFFFF, 255);
    }
    const w = textWidth(text, 1);
    label(s, text, r.x + @divTrunc(r.w - w, 2), r.y + @divTrunc(r.h, 2) - 4, 1, if (!st.enabled) Tone.disabled else if (default) 0xFFFFFF else Tone.text);
}

/// A search field: magnifier, text or placeholder, accent rim when focused.
/// Text that does not fit is cut at the field's edge (never drawn outside).
pub fn searchField(s: *Surface, r: Rect, text: []const u8, placeholder: []const u8, focused: bool) void {
    if (focused) s.rounded(.{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 }, Metrics.field_radius + 2, Tone.accent_soft, 255);
    s.rounded(r, Metrics.field_radius, if (focused) Tone.accent else Tone.field_rim, 255);
    s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, Metrics.field_radius - 1, Tone.field, 255);
    iconTint(s, .search, r.x + 6, r.y + @divTrunc(r.h - 14, 2), 14, Tone.secondary);
    const clip = s.clip;
    defer s.setClip(clip);
    s.setClip(Rect.intersect(clip, .{ .x = r.x + 24, .y = r.y, .w = r.w - 30, .h = r.h }));
    const shown = if (text.len > 0) text else placeholder;
    label(s, shown, r.x + 25, r.y + @divTrunc(r.h, 2) - 4, 1, if (text.len > 0) Tone.text else Tone.placeholder);
    if (focused) {
        const caret = r.x + 25 + (if (text.len > 0) textWidth(text, 1) else 0) + 1;
        s.fill(.{ .x = caret, .y = r.y + 4, .w = 1, .h = r.h - 8 }, Tone.accent);
    }
}

/// A segmented control of `count` equal segments; `selected` is drawn
/// raised, like the Mac's view switcher.
pub fn segmented(s: *const Surface, r: Rect, count: usize, selected: usize, hover: ?usize) void {
    s.rounded(r, Metrics.control_radius, Tone.hover, 255);
    const w = @divTrunc(r.w, @as(i32, @intCast(@max(1, count))));
    for (0..count) |i| {
        const seg = Rect{ .x = r.x + @as(i32, @intCast(i)) * w, .y = r.y, .w = w, .h = r.h };
        if (i == selected) {
            s.rounded(.{ .x = seg.x + 2, .y = seg.y + 3, .w = seg.w - 4, .h = seg.h - 4 }, Metrics.control_radius - 1, 0x000000, 18);
            s.rounded(.{ .x = seg.x + 2, .y = seg.y + 2, .w = seg.w - 4, .h = seg.h - 4 }, Metrics.control_radius - 1, 0xFFFFFF, 255);
        } else if (hover == i) {
            s.rounded(.{ .x = seg.x + 2, .y = seg.y + 2, .w = seg.w - 4, .h = seg.h - 4 }, Metrics.control_radius - 1, Tone.pressed, 255);
        }
    }
}

/// The part of a segmented control a segment covers, for hit testing.
pub fn segment(r: Rect, count: usize, i: usize) Rect {
    const w = @divTrunc(r.w, @as(i32, @intCast(@max(1, count))));
    return .{ .x = r.x + @as(i32, @intCast(i)) * w, .y = r.y, .w = w, .h = r.h };
}

/// One line of editable text: what a rename field, a name sheet or a
/// password field holds. Pure state; `textField` draws it.
pub fn TextInput(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buf: [capacity]u8 = undefined,
        len: usize = 0,
        caret: usize = 0,

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn set(self: *Self, value: []const u8) void {
            self.len = @min(value.len, capacity);
            @memcpy(self.buf[0..self.len], value[0..self.len]);
            self.caret = self.len;
        }
        pub fn clear(self: *Self) void {
            self.len = 0;
            self.caret = 0;
        }
        /// Insert a printable character at the caret; false when full.
        pub fn insert(self: *Self, ch: u8) bool {
            if (ch < 32 or ch > 126 or self.len == capacity) return false;
            var i = self.len;
            while (i > self.caret) : (i -= 1) self.buf[i] = self.buf[i - 1];
            self.buf[self.caret] = ch;
            self.len += 1;
            self.caret += 1;
            return true;
        }
        pub fn backspace(self: *Self) bool {
            if (self.caret == 0) return false;
            self.caret -= 1;
            return self.deleteAtCaret();
        }
        pub fn deleteAtCaret(self: *Self) bool {
            if (self.caret >= self.len) return false;
            var i = self.caret;
            while (i + 1 < self.len) : (i += 1) self.buf[i] = self.buf[i + 1];
            self.len -= 1;
            return true;
        }
        /// Editing keys by set-1 scancode: Backspace, Delete, Left, Right,
        /// Home, End. True when the key was one of them.
        pub fn editKey(self: *Self, code: u8) bool {
            switch (code) {
                0x0E => _ = self.backspace(),
                0x53 => _ = self.deleteAtCaret(),
                0x4B => self.caret -|= 1,
                0x4D => self.caret = @min(self.len, self.caret + 1),
                0x47 => self.caret = 0,
                0x4F => self.caret = self.len,
                else => return false,
            }
            return true;
        }
    };
}

/// A text field around `text`, with the caret after `caret` characters
/// when focused. `secure` shows dots (a password). The text scrolls so the
/// caret stays inside the field and nothing is drawn outside it.
pub fn textField(s: *Surface, r: Rect, text: []const u8, caret: usize, focused: bool, secure: bool, placeholder: []const u8) void {
    if (focused) s.rounded(.{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 }, Metrics.field_radius + 2, Tone.accent_soft, 255);
    s.rounded(r, Metrics.field_radius, if (focused) Tone.accent else Tone.field_rim, 255);
    s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 }, Metrics.field_radius - 1, Tone.field, 255);
    const clip = s.clip;
    defer s.setClip(clip);
    const inner = Rect{ .x = r.x + 7, .y = r.y, .w = r.w - 14, .h = r.h };
    s.setClip(Rect.intersect(clip, inner));
    const base = r.y + @divTrunc(r.h, 2) - 4;
    if (text.len == 0 and !focused) {
        label(s, placeholder, inner.x, base, 1, Tone.placeholder);
        return;
    }
    const dot: i32 = 9;
    const before: i32 = if (secure) @as(i32, @intCast(@min(caret, text.len))) * dot else textWidth(text[0..@min(caret, text.len)], 1);
    const shift = @max(0, before - (inner.w - 2));
    if (secure) {
        for (0..text.len) |i| s.circle(inner.x - shift + @as(i32, @intCast(i)) * dot + 4, r.y + @divTrunc(r.h, 2), 3, Tone.text);
    } else {
        if (text.len == 0) label(s, placeholder, inner.x, base, 1, Tone.placeholder);
        label(s, text, inner.x - shift, base, 1, Tone.text);
    }
    if (focused) s.fill(.{ .x = inner.x - shift + before, .y = r.y + 4, .w = 1, .h = r.h - 8 }, Tone.accent);
}

/// The measured macOS switch (42 x 25): a solid track and a glossy knob.
pub fn switchControl(s: *const Surface, r: Rect, on: bool) void {
    s.rounded(r, @divTrunc(r.h, 2), if (on) Tone.accent else 0xD4D6DB, 255);
    s.rounded(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = 6 }, 5, 0xFFFFFF, if (on) 40 else 70);
    const d = r.h - 4;
    const x = if (on) r.right() - d - 2 else r.x + 2;
    s.rounded(.{ .x = x, .y = r.y + 3, .w = d, .h = d }, @divTrunc(d, 2), 0x000000, 30);
    s.rounded(.{ .x = x, .y = r.y + 2, .w = d, .h = d }, @divTrunc(d, 2), 0xFFFFFF, 255);
}

/// A sheet, as on the Mac: the window dims and a panel asks one question
/// with up to three buttons, the last one the default (accent) action.
pub const Sheet = struct {
    panel: Rect,
    buttons: [3]Rect = undefined,
    count: usize,
    /// Where an optional text field goes (under the message).
    field: Rect,

    pub fn layout(window_w: i32, window_h: i32, button_count: usize, with_field: bool) Sheet {
        const w: i32 = @min(@as(i32, 380), window_w - 32);
        const h: i32 = if (with_field) 176 else 142;
        const panel = Rect{ .x = @divTrunc(window_w - w, 2), .y = @max(8, @divTrunc(window_h - h, 3)), .w = w, .h = h };
        var sheet = Sheet{ .panel = panel, .count = @min(button_count, 3), .field = .{ .x = panel.x + 20, .y = panel.y + 84, .w = w - 40, .h = 24 } };
        const bw: i32 = @min(@as(i32, 104), @divTrunc(w - 40 - 16, 3));
        var x = panel.right() - 20;
        var i = sheet.count;
        while (i > 0) {
            i -= 1;
            x -= bw;
            sheet.buttons[i] = .{ .x = x, .y = panel.bottom() - 20 - Metrics.push_small_h, .w = bw, .h = Metrics.push_small_h };
            x -= 8;
        }
        return sheet;
    }

    pub fn paint(self: Sheet, s: *Surface, window_w: i32, window_h: i32, title: []const u8, message: []const u8, labels: []const []const u8, pointer: Pointer, first_id: u32) void {
        s.rounded(.{ .x = 0, .y = 0, .w = window_w, .h = window_h }, 0, 0x000000, 46);
        const p = self.panel;
        s.rounded(.{ .x = p.x - 1, .y = p.y + 3, .w = p.w + 2, .h = p.h + 3 }, 15, 0x000000, 34);
        s.rounded(p, 14, 0xFFFFFF, 255);
        label(s, fitting(title, p.w - 40), p.x + 20, p.y + 26, 1, Tone.text);
        s.fill(.{ .x = p.x + 20, .y = p.y + 44, .w = p.w - 40, .h = 1 }, Tone.hairline);
        label(s, fitting(message, p.w - 40), p.x + 20, p.y + 58, 1, Tone.secondary);
        for (0..self.count) |i| {
            pushButton(s, self.buttons[i], labels[i], i + 1 == self.count, ControlState.of(pointer, first_id + @as(u32, @intCast(i))));
        }
    }
};

/// The longest prefix of `text` that fits in `width` at text scale 1.
pub fn fitting(text: []const u8, width: i32) []const u8 {
    var n = text.len;
    while (n > 0 and textWidth(text[0..n], 1) > width) n -= 1;
    return text[0..n];
}
/// Capture starts on press; moving onto a button while held cannot activate it.
pub const Pointer = struct {
    hover: u32 = 0,
    pressed: u32 = 0,
    down: bool = false,
    pub fn visualChanged(self: Pointer, old: Pointer) bool {
        return self.hover != old.hover or self.pressed != old.pressed;
    }
    pub fn update(self: *Pointer, x: i32, y: i32, buttons: u8, targets: []const Button) u32 {
        var hit: u32 = 0;
        for (targets) |t| if (t.rect.contains(x, y)) {
            hit = t.id;
            break;
        };
        const down = buttons & 1 != 0;
        self.hover = hit;
        if (down and !self.down) self.pressed = hit;
        const action = if (!down and self.down and self.pressed == hit) hit else 0;
        if (!down) self.pressed = 0;
        self.down = down;
        return action;
    }
};

pub fn surface(win: anytype) Surface {
    return .{ .pixels = win.pixels, .width = win.width, .height = win.height, .stride = win.stride, .scale = win.scale };
}

/// Publish only a completed rectangle from a private frame. This avoids
/// exposing multi-pass construction and reduces compositor work; the row copy
/// is still not the future atomic buffer-ownership protocol.
pub fn publishRegion(win: anytype, pixels: []const u32, rect: Rect) void {
    const r = Rect.intersect(rect, .{ .x = 0, .y = 0, .w = win.width, .h = win.height });
    if (r.isEmpty()) return;
    var y = r.y * win.scale;
    while (y < r.bottom() * win.scale) : (y += 1) {
        const start: usize = @intCast(y * win.stride + r.x * win.scale);
        const n: usize = @intCast(r.w * win.scale);
        @memcpy(win.pixels[start..][0..n], pixels[start..][0..n]);
    }
    win.commit(r.x, r.y, r.w, r.h);
}

pub fn gradient(s: *Surface, r: Rect, radius: i32, top: u32, bottom: u32) void {
    const clip = s.clip;
    defer s.setClip(clip);
    var y = @max(r.y, clip.y);
    while (y < @min(r.bottom(), clip.bottom())) : (y += 1) {
        s.setClip(Rect.intersect(clip, .{ .x = r.x, .y = y, .w = r.w, .h = 1 }));
        s.rounded(r, radius, gfx.lerp(top, bottom, @intCast(@divTrunc((y - r.y) * 255, @max(1, r.h - 1)))), 255);
    }
}

const atlas = @embedFile("icons.bin");
fn u16at(at: usize) usize {
    return @as(usize, atlas[at]) | (@as(usize, atlas[at + 1]) << 8);
}
fn u32at(at: usize) usize {
    return u16at(at) | (u16at(at + 2) << 16);
}
fn spritePixel(offset: usize, width: usize, x: usize, y: usize) u32 {
    const p = offset + (y * width + x) * 4;
    return (@as(u32, atlas[p + 3]) << 24) | (@as(u32, atlas[p]) << 16) | (@as(u32, atlas[p + 1]) << 8) | atlas[p + 2];
}
fn mix(a: u32, b: u32, t: u8) u32 {
    const alpha = ((a >> 24) * (255 - @as(u32, t)) + (b >> 24) * t) / 255;
    return (alpha << 24) | gfx.lerp(a, b, t);
}
/// SVG-derived RGBA sprites; sample at backing resolution, with
/// premultiplied-alpha interpolation so transparent edges have no dark halo.
pub fn icon(s: *const Surface, kind: Icon, x: i32, y: i32, size: i32) void {
    drawIcon(s, kind, x, y, size, null);
}
/// Use the original SVG's antialiased alpha mask with theme-aware ink.
pub fn iconTint(s: *const Surface, kind: Icon, x: i32, y: i32, size: i32, color: u32) void {
    drawIcon(s, kind, x, y, size, color);
}
fn drawIcon(s: *const Surface, kind: Icon, x: i32, y: i32, size: i32, tint: ?u32) void {
    if (size <= 0) return;
    const h = @as(usize, @intFromEnum(kind)) * 8;
    const width = u16at(h);
    const height = u16at(h + 2);
    const offset = u32at(h + 4);
    const r = Rect.intersect(Rect.intersect(.{ .x = x, .y = y, .w = size, .h = size }, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
    const physical = size * s.scale;
    var yy = r.y * s.scale;
    while (yy < r.bottom() * s.scale) : (yy += 1) {
        const sy: usize = @intCast(@max(0, @divTrunc((2 * (yy - y * s.scale) + 1) * @as(i32, @intCast(height)) * 128, physical) - 128));
        const y0 = @min(height - 1, sy >> 8);
        const y1 = @min(height - 1, y0 + 1);
        var xx = r.x * s.scale;
        while (xx < r.right() * s.scale) : (xx += 1) {
            const sx: usize = @intCast(@max(0, @divTrunc((2 * (xx - x * s.scale) + 1) * @as(i32, @intCast(width)) * 128, physical) - 128));
            const x0 = @min(width - 1, sx >> 8);
            const x1 = @min(width - 1, x0 + 1);
            const top = mix(spritePixel(offset, width, x0, y0), spritePixel(offset, width, x1, y0), @truncate(sx));
            const bottom = mix(spritePixel(offset, width, x0, y1), spritePixel(offset, width, x1, y1), @truncate(sx));
            const p = mix(top, bottom, @truncate(sy));
            const alpha = p >> 24;
            if (alpha == 0) continue;
            const bg = s.getPhysical(xx, yy);
            if (tint) |color| {
                s.putPhysical(xx, yy, gfx.lerp(bg, color, @intCast(alpha)));
                continue;
            }
            const red: u32 = @min(255, ((p >> 16) & 255) + ((bg >> 16) & 255) * (255 - alpha) / 255);
            const green: u32 = @min(255, ((p >> 8) & 255) + ((bg >> 8) & 255) * (255 - alpha) / 255);
            const blue: u32 = @min(255, (p & 255) + (bg & 255) * (255 - alpha) / 255);
            s.putPhysical(xx, yy, (red << 16) | (green << 8) | blue);
        }
    }
}

pub fn label(s: *const Surface, str: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
    font.drawText(s, str, x, y, scale, color);
}

/// Eight-logical-pixel cells, matching Squeeze's bundled monospace atlas.
pub fn monoLabel(s: *const Surface, str: []const u8, x: i32, y: i32, color: u32) void {
    for (str, 0..) |ch, i| font.drawMono(s, ch, x + @as(i32, @intCast(i)) * 8, y, color);
}

test "menu symbols match exact Retina output dimensions" {
    const std = @import("std");
    for ([_]Icon{ .menu_wifi, .menu_bluetooth, .menu_speaker, .menu_controls, .menu_brand, .menu_battery, .menu_battery_plain }) |kind| {
        const expected: usize = if (kind == .menu_battery or kind == .menu_battery_plain) 46 else 40;
        const h = @as(usize, @intFromEnum(kind)) * 8;
        try std.testing.expectEqual(expected, u16at(h));
        try std.testing.expectEqual(expected, u16at(h + 2));
    }
}

test "dock icons use prefiltered 88-pixel artwork, not runtime minification" {
    const std = @import("std");
    for ([_]Icon{ .dock_welcome, .dock_terminal, .dock_clock, .dock_about, .dock_windows, .dock_appearance, .dock_files, .dock_trash, .dock_browser }) |kind| {
        const h = @as(usize, @intFromEnum(kind)) * 8;
        try std.testing.expectEqual(@as(usize, 88), u16at(h));
        try std.testing.expectEqual(@as(usize, 88), u16at(h + 2));
    }
}

test "monochrome SVG symbols preserve alpha and theme contrast" {
    const std = @import("std");
    var pixels: [128 * 128]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| {
        var s = Surface{ .pixels = &pixels, .width = 64, .height = 64, .stride = 64 * scale, .scale = scale };
        for ([_]u32{ 0x17334D, 0xF4F7FF }) |color| {
            @memset(&pixels, 0);
            s.setClip(.{ .x = 10, .y = 10, .w = 20, .h = 20 });
            iconTint(&s, .wifi, 0, 0, 40, color);
            var changed: usize = 0;
            for (0..@intCast(64 * scale)) |y| for (0..@intCast(64 * scale)) |x| {
                const p = pixels[y * @as(usize, @intCast(s.stride)) + x];
                if (!s.clip.contains(@divTrunc(@as(i32, @intCast(x)), scale), @divTrunc(@as(i32, @intCast(y)), scale))) {
                    try std.testing.expectEqual(@as(u32, 0), p);
                } else if (p != 0) {
                    changed += 1;
                    inline for (.{ 0, 8, 16 }) |shift| try std.testing.expect(((p >> shift) & 255) <= ((color >> shift) & 255));
                }
            };
            try std.testing.expect(changed > 0);
        }
    }
}

test "every SVG sprite renders at 1x and 2x with clipped alpha edges" {
    const std = @import("std");
    var pixels: [128 * 128]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| {
        var s = Surface{ .pixels = &pixels, .width = 64, .height = 64, .stride = 64 * scale, .scale = scale };
        inline for (std.meta.tags(Icon)) |kind| {
            @memset(&pixels, 0xCACACA);
            s.setClip(.{ .x = 8, .y = 8, .w = 42, .h = 42 });
            icon(&s, kind, 2, 2, 52);
            var changed: usize = 0;
            for (0..@intCast(64 * scale)) |y| for (0..@intCast(64 * scale)) |x| {
                const pixel = pixels[y * @as(usize, @intCast(s.stride)) + x];
                if (!s.clip.contains(@divTrunc(@as(i32, @intCast(x)), scale), @divTrunc(@as(i32, @intCast(y)), scale))) {
                    try std.testing.expectEqual(@as(u32, 0xCACACA), pixel);
                } else if (pixel != 0xCACACA) changed += 1;
            };
            try std.testing.expect(changed > 0);
        }
    }
}

test "toolkit controls stay inside their rectangles" {
    const std = @import("std");
    var pixels: [120 * 60 * 4]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| {
        @memset(&pixels, 0x123456);
        var s = Surface{ .pixels = &pixels, .width = 120, .height = 60, .stride = 120 * scale, .scale = scale };
        const r = Rect{ .x = 10, .y = 10, .w = 90, .h = Metrics.search_h };
        // A long query is cut at the field's edge, never drawn past it.
        searchField(&s, r, "a very long search that will not fit here", "Search", false);
        pushButton(&s, .{ .x = 10, .y = 34, .w = 60, .h = Metrics.push_small_h - 2 }, "OK", true, .{});
        for (0..@intCast(60 * scale)) |y| for (0..@intCast(120 * scale)) |x| {
            const lx = @divTrunc(@as(i32, @intCast(x)), scale);
            const ly = @divTrunc(@as(i32, @intCast(y)), scale);
            const inside = (lx >= 10 and lx < 100 and ly >= 10 and ly < 10 + Metrics.search_h) or (lx >= 10 and lx < 70 and ly >= 34 and ly < 59);
            if (!inside) try std.testing.expectEqual(@as(u32, 0x123456), pixels[y * @as(usize, @intCast(s.stride)) + x]);
        };
    }
    try std.testing.expectEqualStrings("Doc", fitting("Documents", textWidth("Doc", 1)));
    try std.testing.expectEqual(@as(usize, 0), fitting("Documents", 0).len);
}

test "text input edits at the caret and never overflows" {
    const std = @import("std");
    var t: TextInput(6) = .{};
    for ("abc") |c| try std.testing.expect(t.insert(c));
    try std.testing.expect(t.editKey(0x4B)); // left
    try std.testing.expect(t.insert('X'));
    try std.testing.expectEqualStrings("abXc", t.text());
    try std.testing.expect(t.editKey(0x0E)); // backspace removes X
    try std.testing.expectEqualStrings("abc", t.text());
    try std.testing.expect(t.editKey(0x47) and t.editKey(0x53)); // home, delete
    try std.testing.expectEqualStrings("bc", t.text());
    try std.testing.expect(!t.insert(7)); // not printable
    t.set("123456789");
    try std.testing.expectEqualStrings("123456", t.text());
    try std.testing.expect(!t.insert('x')); // full
    try std.testing.expect(!t.editKey(0x1C));
}

test "sheets keep their buttons inside the panel at any window size" {
    const std = @import("std");
    for ([_]i32{ 200, 320, 560, 1262 }) |w| for ([_]usize{ 1, 2, 3 }) |n| {
        const sheet = Sheet.layout(w, 300, n, true);
        try std.testing.expect(sheet.panel.x >= 0 and sheet.panel.right() <= w);
        var last: i32 = sheet.panel.x;
        for (sheet.buttons[0..n]) |b| {
            try std.testing.expect(b.x >= last and b.right() <= sheet.panel.right() - 20 and b.w > 20);
            last = b.right();
        }
        try std.testing.expect(sheet.field.bottom() < sheet.buttons[0].y);
    };
}

test "pointer only activates the originally pressed target" {
    const std = @import("std");
    const buttons = [_]Button{ .{ .id = 1, .rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 } }, .{ .id = 2, .rect = .{ .x = 40, .y = 10, .w = 20, .h = 20 } } };
    var p: Pointer = .{};
    const idle = p;
    try std.testing.expectEqual(@as(u32, 0), p.update(0, 0, 1, &buttons));
    try std.testing.expect(!p.visualChanged(idle));
    try std.testing.expectEqual(@as(u32, 0), p.update(15, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 0), p.update(45, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 1), p.update(15, 15, 0, &buttons));
    _ = p.update(15, 15, 1, &buttons);
    try std.testing.expectEqual(@as(u32, 0), p.update(-100, -100, 0, &buttons));
}

test "private publication clips rows at 1x and 2x and skips empty damage" {
    const std = @import("std");
    const Window = struct {
        width: i32 = 8,
        height: i32 = 6,
        stride: i32,
        scale: i32,
        pixels: [*]u32,
        commits: usize = 0,
        damage: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        pub fn commit(self: *@This(), x: i32, y: i32, w: i32, h: i32) void {
            self.commits += 1;
            self.damage = .{ .x = x, .y = y, .w = w, .h = h };
        }
    };
    var pixels: [8 * 6 * 4]u32 = undefined;
    const source = [_]u32{0xABCDEF} ** pixels.len;
    for ([_]i32{ 1, 2 }) |scale| {
        @memset(&pixels, 0x123456);
        var win = Window{ .stride = 8 * scale, .scale = scale, .pixels = &pixels };
        publishRegion(&win, &source, .{ .x = -2, .y = 2, .w = 5, .h = 8 });
        try std.testing.expectEqual(@as(usize, 1), win.commits);
        try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 2, .w = 3, .h = 4 }, win.damage);
        for (0..@intCast(6 * scale)) |y| for (0..@intCast(8 * scale)) |x| {
            try std.testing.expectEqual(if (y >= 2 * scale and x < 3 * scale) @as(u32, 0xABCDEF) else @as(u32, 0x123456), pixels[y * @as(usize, @intCast(win.stride)) + x]);
        };
        publishRegion(&win, &source, .{ .x = 8, .y = 0, .w = 2, .h = 2 });
        try std.testing.expectEqual(@as(usize, 1), win.commits);
    }
}
