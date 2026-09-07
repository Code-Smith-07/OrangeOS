//! Desktop chrome rendered by Peel, with one shared layout for paint/hit tests.
//! Actions are performed by the compositor; this module never owns processes.
const gfx = @import("gfx");
const ui = @import("ui");
const font = @import("font.zig");
const Rect = gfx.Rect;
const Surface = gfx.Surface;
const pulp = @import("pulp");
const overview = @import("overview.zig");

pub const BAR_H = 36;
pub const DOCK_H = 92;
pub const Action = struct {
    pub const none: u16 = 0;
    pub const home: u16 = 1;
    pub const terminal: u16 = 2;
    pub const clock: u16 = 3;
    pub const about: u16 = 4;
    pub const overview: u16 = 5;
    pub const settings: u16 = 6;
    pub const menu: u16 = 7;
    pub const desktop: u16 = 8;
    pub const new_terminal: u16 = 9;
    pub const dismiss: u16 = 10;
    pub const files: u16 = 11;
    pub const trash: u16 = 12;
    pub const calendar: u16 = 13;
    pub const previous_month: u16 = 14;
    pub const next_month: u16 = 15;
    pub const today: u16 = 16;
    pub const keep_popup: u16 = 17;
    pub const wallpaper: u16 = 20;
    pub const window: u16 = 100;
};
pub const Popup = enum { none, menu, overview, settings, calendar };
pub const Item = struct {
    id: u32 = 0,
    revision: u64 = 0,
    title: []const u8 = "",
    hidden: bool = false,
    app: usize = 0,
    pixels: ?[*]const u32 = null,
    width: i32 = 0,
    height: i32 = 0,
};
pub const State = struct {
    popup: Popup = .none,
    hover: u16 = 0,
    palette: usize = 0,
    active: []const u8 = "Desktop",
    running: [6]bool = .{ false, false, false, false, false, false },
    items: [8]Item = [_]Item{.{}} ** 8,
    count: usize = 0,
    seconds: ?u64 = null,
    month_offset: i32 = 0,
    notice: []const u8 = "",
};

const WHITE = 0xF8F7FF;
const INK = 0x292B49;
const MUTED = 0xB4B7D3;
const COLORS = [_]u32{ 0xFF9258, 0x7879F1, 0xFF5B86, 0x39CFC0, 0x63B5FF, 0xA895F3 };
const LABELS = [_][]const u8{ "Files", "Welcome", "Terminal", "Clock", "About", "Windows", "Appearance", "Trash" };
const DOCK_ACTIONS = [_]u16{ Action.files, Action.home, Action.terminal, Action.clock, Action.about, Action.overview, Action.settings, Action.trash };
const DOCK_ICONS = [_]ui.Icon{ .files, .welcome, .terminal, .clock, .about, .windows, .appearance, .trash };
const DOCK_APPS = [_]?usize{ 4, 0, 1, 2, 3, null, null, 5 };
const PALETTES = [_][5]u32{
    .{ 0x352D90, 0xA878DC, 0xF7B6CB, 0xFF6F50, 0xF8C878 },
    .{ 0x09265E, 0x4876D2, 0x7BE5D7, 0x168BAE, 0x9CEFC2 },
    .{ 0x311A63, 0x905DCF, 0xFDA8DB, 0xCE428A, 0xFA9C74 },
};

/// Smooth ribbons, in normalized coordinates. Integer math keeps the software
/// renderer predictable; wallpaper is cached once per appearance change.
pub fn wallpaperPixel(x: i32, y: i32, width: i32, height: i32, palette: usize) u32 {
    const u = @divTrunc(x * 10000, @max(width, 1));
    const v = @divTrunc(y * 10000, @max(height, 1));
    const p = PALETTES[palette % PALETTES.len];
    const a = u - 7200;
    const ribbon = 1800 + @divTrunc(a * a, 11500) + @divTrunc(u, 4);
    const b = u - 1900;
    const lower = 6400 + @divTrunc(b * b, 24000) - @divTrunc(u, 6);
    const top = gfx.lerp(p[0], p[1], fraction(v, ribbon));
    const middle = gfx.lerp(p[2], p[3], fraction(v - ribbon, lower - ribbon));
    const bottom = gfx.lerp(p[4], p[3], fraction(v - lower, 10000 - lower));
    const first = gfx.lerp(top, middle, fraction(v - ribbon + 12, 24));
    return gfx.lerp(first, bottom, fraction(v - lower + 12, 24));
}

fn fraction(value: i32, total: i32) u8 {
    return @intCast(@max(0, @min(255, @divTrunc(value * 255, @max(1, total)))));
}

pub fn dockRect(s: *const Surface) Rect {
    return .{ .x = @divTrunc(s.width - 664, 2), .y = s.height - DOCK_H - 14, .w = 664, .h = DOCK_H };
}
pub fn dockItem(s: *const Surface, index: usize) Rect {
    const d = dockRect(s);
    return .{ .x = d.x + 16 + @as(i32, @intCast(index)) * 76 + (if (index >= 5) @as(i32, 12) else 0) + (if (index == 7) @as(i32, 12) else 0), .y = d.y + 8, .w = 72, .h = 76 };
}
pub fn popupRect(s: *const Surface, popup: Popup) Rect {
    return switch (popup) {
        .none => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .menu => .{ .x = 12, .y = 44, .w = 270, .h = 220 },
        .settings => .{ .x = s.width - 376, .y = 48, .w = 360, .h = 398 },
        .calendar => .{ .x = s.width - 376, .y = 48, .w = 360, .h = 438 },
        .overview => .{ .x = @divTrunc(s.width - 650, 2), .y = 92, .w = 650, .h = 428 },
    };
}
pub fn windowCard(s: *const Surface, i: usize) Rect {
    const p = popupRect(s, .overview);
    return .{ .x = p.x + 20 + @as(i32, @intCast(i % 2)) * 310, .y = p.y + 94 + @as(i32, @intCast(i / 2)) * 76, .w = 298, .h = 64 };
}
fn paletteCard(s: *const Surface, i: usize) Rect {
    const p = popupRect(s, .settings);
    return .{ .x = p.x + 20 + @as(i32, @intCast(i)) * 108, .y = p.y + 104, .w = 100, .h = 70 };
}

pub fn hit(s: *const Surface, state: *const State, x: i32, y: i32) u16 {
    if (y < BAR_H) {
        if (x < 145) return Action.menu;
        if (x >= s.width - 240) return Action.calendar;
        if (x >= s.width - 300) return Action.settings;
        if (x >= 390 and x < 486) return Action.overview;
        if (x >= 500 and x < 600) return Action.desktop;
        return Action.dismiss;
    }
    for (DOCK_ACTIONS, 0..) |action, i| {
        if (dockItem(s, i).contains(x, y)) return action;
    }
    if (dockRect(s).contains(x, y)) return Action.dismiss;
    if (state.popup != .none) {
        const p = popupRect(s, state.popup);
        if (!p.contains(x, y)) return Action.dismiss;
        switch (state.popup) {
            .menu => {
                if (x < p.x + 12 or x >= p.right() - 12) return Action.dismiss;
                if (y >= p.y + 56 and y < p.y + 196) {
                    const row: usize = @intCast(@divTrunc(y - p.y - 56, 35));
                    return ([_]u16{ Action.home, Action.new_terminal, Action.overview, Action.about })[row];
                }
            },
            .overview => for (0..state.count) |i| {
                if (windowCard(s, i).contains(x, y)) return Action.window + @as(u16, @intCast(i));
            },
            .settings => {
                for (0..3) |i| if (paletteCard(s, i).contains(x, y)) return Action.wallpaper + @as(u16, @intCast(i));
                if ((Rect{ .x = p.x + 20, .y = p.y + 210, .w = 320, .h = 40 }).contains(x, y)) return Action.desktop;
            },
            .calendar => {
                for ([_]u16{ Action.previous_month, Action.next_month, Action.today, Action.clock }) |action| {
                    if (calendarButton(s, action).contains(x, y)) return action;
                }
                return Action.keep_popup;
            },
            .none => {},
        }
        return Action.dismiss;
    }
    return Action.none;
}

fn text(s: *const Surface, str: []const u8, x: i32, y: i32, color: u32) void {
    font.drawText(s, str, x, y, 1, color);
}
fn centered(s: *const Surface, str: []const u8, r: Rect, color: u32) void {
    text(s, str, r.x + @divTrunc(r.w - font.textWidth(str, 1), 2), r.y + @divTrunc(r.h - 8, 2), color);
}
fn glass(s: *const Surface, r: Rect, radius: i32, opacity: u8) void {
    glassMaterial(s, r, radius, opacity, null);
}
// Exact backdrop comparison keeps live underlying windows correct, while
// stable button hover/navigation does not rerun the expensive blur.
var calendar_material: gfx.FrostCache(700_000) = .{};
fn glassMaterial(s: *const Surface, r: Rect, radius: i32, opacity: u8, cache: ?*gfx.FrostCache(700_000)) void {
    var spread: i32 = 8;
    while (spread > 0) : (spread -= 1) {
        s.rounded(.{ .x = r.x - spread, .y = r.y + 3, .w = r.w + spread * 2, .h = r.h + spread }, radius + spread, 0x17182F, 4);
    }
    if (cache) |material| material.paint(s, r, radius, 0x22243D, @min(opacity, 168)) else s.frost(r, radius, 0x22243D, @min(opacity, 168));
    // Fine luminous rim, without filling the interior a second time.
    const inner = Rect{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 };
    var rim = s.*;
    for ([_]Rect{
        .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 },
        .{ .x = r.x, .y = r.y + 1, .w = 1, .h = r.h - 2 },
        .{ .x = inner.right(), .y = r.y + 1, .w = 1, .h = r.h - 2 },
        .{ .x = r.x, .y = inner.bottom(), .w = r.w, .h = 1 },
    }) |strip| {
        rim.setClip(Rect.intersect(s.clip, strip));
        rim.rounded(r, radius, WHITE, 90);
    }
}

/// All backdrop readers participate in damage closure. Tooltip/toast extents
/// are included conservatively so hover changes cannot leave stale frost.
pub fn expandDamage(s: *const Surface, state: *const State, damage: Rect) Rect {
    var out = gfx.expandForGlass(damage, .{ .x = 0, .y = 0, .w = s.width, .h = BAR_H });
    const dock = dockRect(s);
    out = gfx.expandForGlass(out, gfx.shadowExtent(dock));
    if (state.hover != 0 or state.notice.len > 0)
        out = gfx.expandForGlass(out, .{ .x = dock.x - 32, .y = dock.y - 90, .w = dock.w + 64, .h = 90 });
    if (state.popup != .none) out = gfx.expandForGlass(out, popupRect(s, state.popup));
    return out;
}

/// Only surfaces whose appearance depends on hover need new scene pixels.
/// Menu-bar labels do not change on hover. A dismiss hit is not a highlight.
pub fn hoverDamage(s: *const Surface, state: *const State, old: u16, new: u16) Rect {
    var damage = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (DOCK_ACTIONS) |action| {
        if (old == action or new == action) {
            const d = dockRect(s);
            damage = .{ .x = d.x - 12, .y = d.y - 45, .w = d.w + 24, .h = d.h + 65 };
            break;
        }
    }
    if (state.popup != .none and state.popup != .overview and (old >= Action.window or new >= Action.window or
        old == Action.desktop or new == Action.desktop or state.popup == .menu or
        (state.popup == .calendar and (calendarHover(old) or calendarHover(new)))))
        damage = Rect.unionWith(damage, popupRect(s, state.popup));
    return damage;
}

fn calendarHover(action: u16) bool {
    return action == Action.clock or (action >= Action.previous_month and action <= Action.today);
}

fn calendarButton(s: *const Surface, action: u16) Rect {
    const p = popupRect(s, .calendar);
    return switch (action) {
        Action.previous_month => .{ .x = p.x + 264, .y = p.y + 120, .w = 32, .h = 28 },
        Action.next_month => .{ .x = p.x + 302, .y = p.y + 120, .w = 32, .h = 28 },
        Action.today => .{ .x = p.x + 244, .y = p.y + 37, .w = 88, .h = 30 },
        else => .{ .x = p.x + 20, .y = p.y + 382, .w = 320, .h = 36 },
    };
}

fn paintCalendar(s: *const Surface, state: *const State) void {
    const p = popupRect(s, .calendar);
    const seconds = state.seconds orelse {
        text(s, "Hardware clock unavailable", p.x + 20, p.y + 30, WHITE);
        return;
    };
    const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
    const month = pulp.calendar.monthAt(date, state.month_offset);
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    var buf: [64]u8 = undefined;
    // A tinted date tile inside the frosted panel, rather than fake weather.
    s.rounded(.{ .x = p.x + 12, .y = p.y + 12, .w = 336, .h = 90 }, 15, 0xAD98F8, 40);
    text(s, weekdays[date.weekday], p.x + 25, p.y + 27, 0xFFBCAC);
    const day = @import("std").fmt.bufPrint(&buf, "{d}", .{date.day}) catch "";
    font.drawText(s, day, p.x + 24, p.y + 48, 3, WHITE);
    const time = @import("std").fmt.bufPrint(&buf, "{d}:{d:0>2} {s}", .{ if (date.hour % 12 == 0) @as(u8, 12) else date.hour % 12, date.minute, if (date.hour < 12) "AM" else "PM" }) catch "";
    text(s, time, p.x + 96, p.y + 56, WHITE);
    text(s, "LOCAL TIME", p.x + 96, p.y + 77, MUTED);
    const title = @import("std").fmt.bufPrint(&buf, "{s} {d}", .{ months[month.month - 1], month.year }) catch "";
    text(s, title, p.x + 24, p.y + 131, WHITE);
    const names = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };
    for (names, 0..) |name, i| {
        centered(s, name, .{ .x = p.x + 23 + @as(i32, @intCast(i)) * 45, .y = p.y + 160, .w = 42, .h = 24 }, MUTED);
    }
    var d: u8 = 1;
    while (d <= pulp.calendar.daysInMonth(month.year, month.month)) : (d += 1) {
        const index: i32 = @as(i32, month.weekday) + d - 1;
        const r = Rect{ .x = p.x + 23 + @mod(index, 7) * 45, .y = p.y + 188 + @divTrunc(index, 7) * 30, .w = 42, .h = 28 };
        const today = month.year == date.year and month.month == date.month and d == date.day;
        if (today) s.rounded(.{ .x = r.x + 7, .y = r.y, .w = 28, .h = 28 }, 14, 0xF2768E, 255);
        const label = @import("std").fmt.bufPrint(&buf, "{d}", .{d}) catch "";
        centered(s, label, r, WHITE);
    }
    for ([_]u16{ Action.previous_month, Action.next_month, Action.today, Action.clock }) |action| {
        const r = calendarButton(s, action);
        if (action == Action.previous_month or action == Action.next_month) {
            s.rounded(r, 9, WHITE, if (state.hover == action) 240 else 200);
            ui.icon(s, if (action == Action.previous_month) .chevron_left else .chevron_right, r.x + 6, r.y + 4, 20);
        } else {
            s.rounded(r, 9, 0xC5B4FF, if (state.hover == action) 110 else 38);
            centered(s, if (action == Action.today) "Today" else "Open Clock", r, WHITE);
        }
    }
}

// Two bounded caches consume 4.8 MB, preserving the exact frosted pixels.
var bar_material: gfx.FrostCache(300_000) = .{};
var dock_material: gfx.FrostCache(300_000) = .{};
var overview_base: overview.Base = .{};
var previews: [8]overview.Preview = [_]overview.Preview{.{}} ** 8;

pub fn overviewValid() bool {
    return overview_base.valid;
}

pub fn invalidateOverview() void {
    overview_base.valid = false;
}

pub fn paintOverviewUpdate(s: *const Surface, state: *const State) bool {
    if (state.popup != .overview or !overview_base.restore(s)) return false;
    paintOverviewCards(s, state);
    return true;
}

fn paintOverviewCards(s: *const Surface, state: *const State) void {
    for (0..state.count) |i| {
        const r = windowCard(s, i);
        if (!Rect.overlaps(r, s.clip)) continue;
        const item = state.items[i];
        s.rounded(r, 12, if (state.hover == Action.window + i) 0xB4A5F7 else 0xE9E5FF, if (state.hover == Action.window + i) 90 else 28);
        s.rounded(.{ .x = r.x + 10, .y = r.y + 9, .w = 76, .h = 46 }, 5, COLORS[item.app % 6], 255);
        if (item.pixels) |pixels| previews[i].paint(s, pixels, item.id, item.revision, item.width, item.height, r.x + 12, r.y + 15);
        text(s, item.title[0..@min(26, item.title.len)], r.x + 98, r.y + 17, WHITE);
        text(s, if (item.hidden) "Minimized - restore" else "Open - switch here", r.x + 98, r.y + 40, MUTED);
    }
}

pub fn paint(s: *const Surface, state: *const State) void {
    // Translucent top strip with only real, actionable menus/status.
    bar_material.paint(s, .{ .x = 0, .y = 0, .w = s.width, .h = BAR_H }, 0, 0xF4ECFF, 186);
    ui.icon(s, .brand, 12, 6, 24);
    text(s, "Orange OS", 42, 14, INK);
    text(s, state.active[0..@min(state.active.len, 25)], 162, 14, 0x565270);
    text(s, "Windows", 398, 14, INK);
    text(s, "Desktop", 510, 14, INK);
    if (state.popup == .calendar) s.rounded(.{ .x = s.width - 242, .y = 4, .w = 232, .h = 28 }, 9, WHITE, 100);
    if (state.seconds) |seconds| {
        const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
        var date_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        var bar_buf: [64]u8 = undefined;
        const label = @import("std").fmt.bufPrint(&bar_buf, "{s}  {s}", .{ pulp.calendar.dateText(&date_buf, date), pulp.calendar.clockText(&time_buf, date) }) catch "";
        text(s, label, s.width - font.textWidth(label, 1) - 18, 14, INK);
    } else text(s, "Clock unavailable", s.width - 180, 14, INK);
    ui.icon(s, .controls, s.width - 280, 6, 24);

    const dock = dockRect(s);
    // A translucent pearl shelf with a fine rim and separate utility groups.
    dock_material.paintShadowed(s, dock, 25, 0xEAEAFB, 104);
    s.rounded(.{ .x = dock.x + 20, .y = dock.y, .w = dock.w - 40, .h = 1 }, 0, 0xFFFFFF, 185);
    s.rounded(.{ .x = dock.x + 410, .y = dock.y + 20, .w = 1, .h = 49 }, 0, 0x686583, 70);
    s.rounded(.{ .x = dock.x + 575, .y = dock.y + 20, .w = 1, .h = 49 }, 0, 0x686583, 70);
    var drawing = s.*;
    for (DOCK_ACTIONS, 0..) |action, i| {
        const r = dockItem(s, i);
        const hovered = state.hover == action;
        if (hovered) s.rounded(.{ .x = r.x, .y = r.y - 2, .w = r.w, .h = r.h }, 19, WHITE, 42);
        ui.icon(&drawing, DOCK_ICONS[i], r.x + (if (hovered) @as(i32, 3) else 6), r.y + (if (hovered) @as(i32, -4) else 0), if (hovered) 66 else 60);
        if (DOCK_APPS[i]) |app| if (state.running[app]) {
            s.circle(r.x + 36, r.y + 70, 2, 0x4C5277);
        };
        if (hovered) {
            const tw = font.textWidth(LABELS[i], 1) + 24;
            const tag = Rect{ .x = r.x + @divTrunc(r.w - tw, 2), .y = dock.y - 40, .w = tw, .h = 28 };
            glass(s, tag, 8, 242);
            centered(s, LABELS[i], tag, WHITE);
        }
    }

    if (state.notice.len > 0) {
        const toast = Rect{ .x = @divTrunc(s.width - 400, 2), .y = dock.y - 88, .w = 400, .h = 36 };
        glass(s, toast, 12, 242);
        centered(s, state.notice, toast, WHITE);
    }
    if (state.popup == .none) return;
    const p = popupRect(s, state.popup);
    if (!Rect.overlaps(gfx.shadowExtent(p), s.clip)) return;
    if (state.popup == .calendar) glassMaterial(s, p, 18, 242, &calendar_material) else glass(s, p, 18, 242);
    switch (state.popup) {
        .menu => {
            text(s, "A little more possibility.", p.x + 18, p.y + 24, MUTED);
            const labels = [_][]const u8{ "Welcome to Orange", "New terminal", "All windows", "About Orange OS" };
            const actions = [_]u16{ Action.home, Action.new_terminal, Action.overview, Action.about };
            for (labels, 0..) |label, i| {
                const r = Rect{ .x = p.x + 12, .y = p.y + 56 + @as(i32, @intCast(i)) * 35, .w = p.w - 24, .h = 33 };
                if (state.hover == actions[i]) s.rounded(r, 7, 0xA18CEF, 100);
                text(s, label, r.x + 10, r.y + 12, WHITE);
            }
        },
        .overview => {
            font.drawText(s, "Your workspace", p.x + 22, p.y + 24, 2, WHITE);
            text(s, "Every open window. Click to switch or restore.", p.x + 22, p.y + 62, MUTED);
            if (state.count == 0) text(s, "A fresh start. Open an app from the dock.", p.x + 22, p.y + 116, WHITE);
            overview_base.capture(s, p);
            paintOverviewCards(s, state);
        },
        .settings => {
            font.drawText(s, "Make it yours", p.x + 20, p.y + 25, 2, WHITE);
            text(s, "DESKTOP WALLPAPER", p.x + 20, p.y + 78, MUTED);
            const names = [_][]const u8{ "Daybreak", "Lagoon", "Orchid" };
            for (0..3) |i| {
                const r = paletteCard(s, i);
                s.rounded(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, 10, if (state.palette == i) WHITE else 0x656278, 255);
                var yy = r.y * s.scale;
                while (yy < r.bottom() * s.scale) : (yy += 1) {
                    var xx = r.x * s.scale;
                    while (xx < r.right() * s.scale) : (xx += 1) {
                        const rad = 7 * s.scale;
                        const dx = @max(@max(r.x * s.scale + rad - xx - 1, xx - (r.right() * s.scale - rad)), 0);
                        const dy = @max(@max(r.y * s.scale + rad - yy - 1, yy - (r.bottom() * s.scale - rad)), 0);
                        const d = dx * dx + dy * dy;
                        if (d > rad * rad) continue;
                        const coverage: u8 = if (d > rad * rad - 2 * rad) @intCast(@divTrunc((rad * rad - d) * 255, 2 * rad)) else 255;
                        const color = wallpaperPixel(xx - r.x * s.scale, yy - r.y * s.scale, r.w * s.scale, r.h * s.scale, i);
                        s.putPhysical(xx, yy, gfx.lerp(s.getPhysical(xx, yy), color, coverage));
                    }
                }
                centered(s, names[i], .{ .x = r.x, .y = r.bottom() + 10, .w = r.w, .h = 14 }, WHITE);
            }
            const button = Rect{ .x = p.x + 20, .y = p.y + 210, .w = 320, .h = 40 };
            s.rounded(button, 10, if (state.hover == Action.desktop) 0x8173CB else 0x555071, 255);
            centered(s, "Show / restore desktop", button, WHITE);
            text(s, "THIS SESSION", p.x + 20, p.y + 280, MUTED);
            var buffer: [64]u8 = undefined;
            const dimensions = @import("std").fmt.bufPrint(&buffer, "Display  {d} x {d}  /  {d}x UI", .{ s.width * s.scale, s.height * s.scale, s.scale }) catch "Display information unavailable";
            text(s, dimensions, p.x + 20, p.y + 305, WHITE);
            text(s, "Green button: zoom / restore", p.x + 20, p.y + 328, MUTED);
            text(s, "Wallpaper choice resets on reboot.", p.x + 20, p.y + 358, MUTED);
        },
        .calendar => paintCalendar(s, state),
        .none => {},
    }
}
