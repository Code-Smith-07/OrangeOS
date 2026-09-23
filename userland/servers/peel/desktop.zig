//! Desktop chrome rendered by Peel, with one shared layout for paint/hit tests.
//! Actions are performed by the compositor; this module never owns processes.
const gfx = @import("gfx");
const ui = @import("ui");
const font = @import("font.zig");
const Rect = gfx.Rect;
const Surface = gfx.Surface;
const pulp = @import("pulp");
const overview = @import("overview.zig");
const host_model = @import("host_model");

pub const BAR_H = 28;
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
    pub const hardware: u16 = 18;
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
    running: [7]bool = [_]bool{false} ** 7,
    items: [8]Item = [_]Item{.{}} ** 8,
    count: usize = 0,
    seconds: ?u64 = null,
    month_offset: i32 = 0,
    notice: []const u8 = "",
    host: host_model.Model = .{},
};

pub const ThemeColors = struct {
    ink: u32,
    muted: u32,
    accent: u32,
    surface: u32,
    bar: u32,
    dock: u32,
    panel: u32,
    hover: u32,
    rim: u32,
    // Light materials catch a bright edge; dark materials rely on silhouette
    // and shadow, without a luminous one-point outline.
    edge_highlights: bool = true,
    frame: u32,
    frame_inactive: u32,
    frame_text: u32,
};
pub const THEME_NAMES = [_][]const u8{ "Coastal Glass", "Citrus Atelier", "Midnight Aurora" };
const THEMES = [_]ThemeColors{
    .{ .ink = 0x26313E, .muted = 0x78818D, .accent = 0x1689DB, .surface = 0xFFFFFF, .bar = 0xF2FAFF, .dock = 0xF1F5F8, .panel = 0xF4FAFF, .hover = 0xD9EFFD, .rim = 0xFFFFFF, .frame = 0xF5F5F7, .frame_inactive = 0xECEDEF, .frame_text = 0x36383D },
    .{ .ink = 0x4A2B36, .muted = 0x816A74, .accent = 0xDF5D32, .surface = 0xFFF9F4, .bar = 0xFFF3E9, .dock = 0xFFEDE5, .panel = 0xFFF4EE, .hover = 0xFFE4D8, .rim = 0xFFFFFF, .frame = 0xFFF7F1, .frame_inactive = 0xF6E4DF, .frame_text = 0x4A2B36 },
    .{ .ink = 0xF4F7FF, .muted = 0xBDC9E0, .accent = 0x69E5E0, .surface = 0x263556, .bar = 0x14243F, .dock = 0x1E3154, .panel = 0x1C2D4B, .hover = 0x345272, .rim = 0xBAD8FB, .edge_highlights = false, .frame = 0x233653, .frame_inactive = 0x1A2942, .frame_text = 0xF4F7FF },
};
pub fn themeColors(index: usize) ThemeColors {
    return THEMES[index % THEMES.len];
}
// Peel is single-threaded. Calendar/overview retained-layer updates use the
// same active palette as full shell paints without allocating new surfaces.
var WHITE: u32 = THEMES[0].surface;
var INK: u32 = THEMES[0].ink;
var MUTED: u32 = THEMES[0].muted;
var ACCENT: u32 = THEMES[0].accent;
var active_theme: ThemeColors = THEMES[0];
fn activateTheme(index: usize) void {
    active_theme = themeColors(index);
    WHITE = active_theme.surface;
    INK = active_theme.ink;
    MUTED = active_theme.muted;
    ACCENT = active_theme.accent;
}
const COLORS = [_]u32{ 0xFF9258, 0x7879F1, 0xFF5B86, 0x39CFC0, 0x63B5FF, 0xA895F3 };
const LABELS = [_][]const u8{ "Files", "Welcome", "Terminal", "Clock", "About", "Windows", "Appearance", "Trash" };
const DOCK_ACTIONS = [_]u16{ Action.files, Action.home, Action.terminal, Action.clock, Action.about, Action.overview, Action.settings, Action.trash };
const DOCK_ICONS = [_]ui.Icon{ .files, .welcome, .terminal, .clock, .about, .windows, .appearance, .trash };
const DOCK_APPS = [_]?usize{ 4, 0, 1, 2, 3, null, null, 5 };
// Clean assets derived from the three approved concepts. The BMP resources
// live on CitrusFS, not inside Peel's ELF (the kernel has an 8 MiB exec cap).
// Peel loads each once into bounded SHM and installs a read-only slice here.
const bitmap_width: i32 = 1280;
const bitmap_height: i32 = 800;
pub const WALLPAPER_BYTES: usize = 54 + bitmap_width * bitmap_height * 3;
var wallpaper_bmps: [THEMES.len]?[]const u8 = [_]?[]const u8{null} ** THEMES.len;
pub fn installWallpaperSource(index: usize, bmp: []const u8) bool {
    if (index >= wallpaper_bmps.len or bmp.len != WALLPAPER_BYTES or
        bmp[0] != 'B' or bmp[1] != 'M' or bmp[28] != 24 or bmp[29] != 0)
        return false;
    wallpaper_bmps[index] = bmp;
    return true;
}

/// All three wallpapers are cached at native backing resolution. Pointer
/// motion never re-evaluates these pixels.
pub fn wallpaperPixel(x: i32, y: i32, width: i32, height: i32, palette: usize) u32 {
    const index = palette % wallpaper_bmps.len;
    if (wallpaper_bmps[index]) |bmp| return bitmapPixel(x, y, width, height, bmp);
    const t: u8 = @intCast(@max(0, @min(255, @divTrunc(y * 255, @max(1, height - 1)))));
    const fallback = [_][2]u32{ .{ 0x8BCBF5, 0x196ABD }, .{ 0xF4A7A7, 0xFF8A66 }, .{ 0x101A3A, 0x273D69 } };
    return gfx.lerp(fallback[index][0], fallback[index][1], t);
}

fn sourcePixel(bmp: []const u8, x: usize, y: usize) u32 {
    const at = 54 + (y * @as(usize, bitmap_width) + x) * 3;
    return (@as(u32, bmp[at + 2]) << 16) | (@as(u32, bmp[at + 1]) << 8) | bmp[at];
}

fn bitmapPixel(x: i32, y: i32, width: i32, height: i32, bmp: []const u8) u32 {
    const sx: usize = @intCast(@divTrunc(@max(0, x) * (bitmap_width - 1) * 256, @max(1, width - 1)));
    const sy: usize = @intCast(@divTrunc(@max(0, y) * (bitmap_height - 1) * 256, @max(1, height - 1)));
    const x0 = @min(@as(usize, bitmap_width - 1), sx >> 8);
    const y0 = @min(@as(usize, bitmap_height - 1), sy >> 8);
    const x1 = @min(@as(usize, bitmap_width - 1), x0 + 1);
    const y1 = @min(@as(usize, bitmap_height - 1), y0 + 1);
    const top = gfx.lerp(sourcePixel(bmp, x0, y0), sourcePixel(bmp, x1, y0), @truncate(sx));
    const bottom = gfx.lerp(sourcePixel(bmp, x0, y1), sourcePixel(bmp, x1, y1), @truncate(sx));
    return gfx.lerp(top, bottom, @truncate(sy));
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
        .settings => .{ .x = s.width - 376, .y = 48, .w = 360, .h = 450 },
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
        if (x >= s.width - (if (s.width >= 1160) @as(i32, 480) else 300)) return Action.hardware;
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
                if (hardwareButton(s).contains(x, y)) return Action.hardware;
                return Action.keep_popup;
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
var calendar_shadow: overview.Base = .{};
pub fn calendarSourceDamage(damage: ?Rect) void {
    calendar_material.source_damage = damage;
}
fn glassMaterial(s: *const Surface, r: Rect, radius: i32, opacity: u8, cache: ?*gfx.FrostCache(700_000)) void {
    if (cache != null) {
        // Calendar shadow uses the compositor's edge-only shadow renderer.
        // Eight translucent fills of its entire interior dominated cold opens.
        if (calendar_material.source_damage) |changed| {
            if (calendar_shadow.valid) {
                var patch = s.*;
                patch.setClip(Rect.intersect(s.clip, changed));
                gfx.windowShadow(&patch, r, false);
                calendar_shadow.refresh(&patch);
                _ = calendar_shadow.restore(s);
            } else {
                gfx.windowShadow(s, r, false);
                calendar_shadow.capture(s, popupExtent(s, .calendar));
            }
        } else {
            gfx.windowShadow(s, r, false);
            calendar_shadow.capture(s, popupExtent(s, .calendar));
        }
    } else {
        var spread: i32 = 8;
        while (spread > 0) : (spread -= 1) {
            s.rounded(.{ .x = r.x - spread, .y = r.y + 3, .w = r.w + spread * 2, .h = r.h + spread }, radius + spread, 0x17182F, 4);
        }
    }
    if (cache) |material| material.paint(s, r, radius, active_theme.panel, @min(opacity, 226)) else s.frost(r, radius, active_theme.panel, @min(opacity, 226));
    glassRim(s, r, radius);
}

fn glassRim(s: *const Surface, r: Rect, radius: i32) void {
    if (!active_theme.edge_highlights) return;
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
        rim.rounded(r, radius, active_theme.rim, 90);
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
    if (state.popup != .none) out = gfx.expandForGlass(out, popupExtent(s, state.popup));
    return out;
}

/// Only surfaces whose appearance depends on hover need new scene pixels.
/// Menu-bar labels do not change on hover. A dismiss hit is not a highlight.
pub fn hoverDamage(s: *const Surface, state: *const State, old: u16, new: u16) Rect {
    var damage = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (DOCK_ACTIONS) |action| {
        // Calendar's Open Clock shares the launch action, not dock hover art.
        if (state.popup == .calendar and calendarHover(action)) continue;
        if (old == action or new == action) {
            const d = dockRect(s);
            damage = .{ .x = d.x - 12, .y = d.y - 45, .w = d.w + 24, .h = d.h + 65 };
            break;
        }
    }
    if (state.popup != .none and state.popup != .overview and (old >= Action.window or new >= Action.window or
        old == Action.desktop or new == Action.desktop or old == Action.hardware or new == Action.hardware or state.popup == .menu))
        damage = Rect.unionWith(damage, popupRect(s, state.popup));
    return damage;
}

pub fn calendarHover(action: u16) bool {
    return action == Action.clock or (action >= Action.previous_month and action <= Action.today);
}

pub fn calendarButton(s: *const Surface, action: u16) Rect {
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
        text(s, "Hardware clock unavailable", p.x + 20, p.y + 30, INK);
        return;
    };
    const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
    const month = pulp.calendar.monthAt(date, state.month_offset);
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    var buf: [64]u8 = undefined;
    // A tinted date tile inside the frosted panel, rather than fake weather.
    s.rounded(.{ .x = p.x + 12, .y = p.y + 12, .w = 336, .h = 90 }, 15, WHITE, 150);
    text(s, weekdays[date.weekday], p.x + 25, p.y + 27, ACCENT);
    const day = @import("std").fmt.bufPrint(&buf, "{d}", .{date.day}) catch "";
    font.drawText(s, day, p.x + 24, p.y + 48, 3, INK);
    const time = @import("std").fmt.bufPrint(&buf, "{d}:{d:0>2} {s}", .{ if (date.hour % 12 == 0) @as(u8, 12) else date.hour % 12, date.minute, if (date.hour < 12) "AM" else "PM" }) catch "";
    text(s, time, p.x + 96, p.y + 56, INK);
    text(s, "Local time", p.x + 96, p.y + 77, MUTED);
    const title = @import("std").fmt.bufPrint(&buf, "{s} {d}", .{ months[month.month - 1], month.year }) catch "";
    text(s, title, p.x + 24, p.y + 131, INK);
    const names = [_][]const u8{ "S", "M", "T", "W", "T", "F", "S" };
    for (names, 0..) |name, i| {
        centered(s, name, .{ .x = p.x + 23 + @as(i32, @intCast(i)) * 45, .y = p.y + 160, .w = 42, .h = 24 }, MUTED);
    }
    var d: u8 = 1;
    while (d <= pulp.calendar.daysInMonth(month.year, month.month)) : (d += 1) {
        const index: i32 = @as(i32, month.weekday) + d - 1;
        const r = Rect{ .x = p.x + 23 + @mod(index, 7) * 45, .y = p.y + 188 + @divTrunc(index, 7) * 30, .w = 42, .h = 28 };
        const today = month.year == date.year and month.month == date.month and d == date.day;
        if (today) s.rounded(.{ .x = r.x + 7, .y = r.y, .w = 28, .h = 28 }, 14, ACCENT, 255);
        const label = @import("std").fmt.bufPrint(&buf, "{d}", .{d}) catch "";
        centered(s, label, r, if (today) WHITE else INK);
    }
    for ([_]u16{ Action.previous_month, Action.next_month, Action.today, Action.clock }) |action| {
        const r = calendarButton(s, action);
        if (action == Action.previous_month or action == Action.next_month) {
            s.rounded(r, 9, WHITE, if (state.hover == action) 240 else 200);
            ui.icon(s, if (action == Action.previous_month) .chevron_left else .chevron_right, r.x + 6, r.y + 4, 20);
        } else {
            s.rounded(r, 9, if (state.hover == action) 0xD7E5FB else WHITE, 210);
            centered(s, if (action == Action.today) "Today" else "Open Clock", r, ACCENT);
        }
    }
}

// Two bounded caches consume 4.8 MB, preserving the exact frosted pixels.
var bar_material: gfx.FrostCache(300_000) = .{};
var dock_material: gfx.FrostCache(300_000) = .{};
// One reusable bounded cache for the mutually exclusive shell panels. Unlike
// snapshotting a finished UI, exact source comparison keeps live windows live.
var panel_material: gfx.FrostCache(1_200_000) = .{};
var overview_base: overview.Base = .{};
var calendar_base: overview.Base = .{};
var calendar_underlay: overview.Base = .{};
var calendar_finished: overview.Base = .{};
const CalendarKey = struct { minute: ?u64, month: i32, hover: u16 };
var calendar_key: ?CalendarKey = null;
fn calendarKey(state: *const State) CalendarKey {
    return .{ .minute = if (state.seconds) |seconds| seconds / 60 else null, .month = state.month_offset, .hover = state.hover };
}

pub fn calendarUnderlayValid() bool {
    return calendar_underlay.valid;
}
pub fn captureCalendarUnderlay(s: *const Surface) void {
    calendar_underlay.capture(s, popupExtent(s, .calendar));
}
pub fn restoreCalendarUnderlay(s: *const Surface) bool {
    return calendar_underlay.restore(s);
}

pub fn calendarValid() bool {
    return calendar_base.valid;
}
pub fn popupExtent(s: *const Surface, popup: Popup) Rect {
    const r = popupRect(s, popup);
    return if (popup == .calendar) .{ .x = r.x - 14, .y = r.y - 8, .w = r.w + 28, .h = r.h + 28 } else gfx.shadowExtent(r);
}
pub fn invalidateCalendar() void {
    calendar_base.valid = false;
    calendar_underlay.valid = false;
    calendar_finished.valid = false;
    calendar_key = null;
    calendar_shadow.valid = false;
}
pub fn paintCalendarUpdate(s: *const Surface, state: *const State) bool {
    activateTheme(state.palette);
    if (state.popup != .calendar or !calendar_base.restore(s)) return false;
    paintCalendar(s, state);
    calendar_finished.refresh(s);
    calendar_key = calendarKey(state);
    return true;
}
var previews: [8]overview.Preview = [_]overview.Preview{.{}} ** 8;

pub fn overviewValid() bool {
    return overview_base.valid;
}

pub fn invalidateOverview() void {
    overview_base.valid = false;
}

pub fn paintOverviewUpdate(s: *const Surface, state: *const State) bool {
    activateTheme(state.palette);
    if (state.popup != .overview or !overview_base.restore(s)) return false;
    paintOverviewCards(s, state);
    return true;
}

fn paintOverviewCards(s: *const Surface, state: *const State) void {
    for (0..state.count) |i| {
        const r = windowCard(s, i);
        if (!Rect.overlaps(r, s.clip)) continue;
        const item = state.items[i];
        s.rounded(r, 12, if (state.hover == Action.window + i) active_theme.hover else WHITE, 195);
        s.rounded(.{ .x = r.x + 10, .y = r.y + 9, .w = 76, .h = 46 }, 5, COLORS[item.app % 6], 255);
        if (item.pixels) |pixels| previews[i].paint(s, pixels, item.id, item.revision, item.width, item.height, r.x + 12, r.y + 15);
        text(s, item.title[0..@min(26, item.title.len)], r.x + 98, r.y + 17, INK);
        text(s, if (item.hidden) "Minimized" else "Open window", r.x + 98, r.y + 40, MUTED);
    }
}

pub fn paint(s: *const Surface, state: *const State) void {
    activateTheme(state.palette);
    // Translucent top strip with only real, actionable menus/status.
    bar_material.paint(s, .{ .x = 0, .y = 0, .w = s.width, .h = BAR_H }, 0, active_theme.bar, 222);
    ui.icon(s, .brand, 14, 4, 20);
    text(s, "Orange OS", 42, 10, INK);
    text(s, state.active[0..@min(state.active.len, 25)], 162, 10, INK);
    text(s, "Windows", 398, 10, INK);
    text(s, "Desktop", 510, 10, INK);
    if (state.popup == .calendar) s.rounded(.{ .x = s.width - 242, .y = 3, .w = 232, .h = 22 }, 7, WHITE, 100);
    if (state.seconds) |seconds| {
        const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
        var date_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        var bar_buf: [64]u8 = undefined;
        const label = @import("std").fmt.bufPrint(&bar_buf, "{s}  {s}", .{ pulp.calendar.dateText(&date_buf, date), pulp.calendar.clockText(&time_buf, date) }) catch "";
        text(s, label, s.width - font.textWidth(label, 1) - 18, 10, INK);
    } else text(s, "Clock unavailable", s.width - 180, 10, INK);
    ui.iconTint(s, .controls, s.width - 278, 4, 20, INK);
    paintHostStatus(s, state);

    const dock = dockRect(s);
    // A translucent shelf; only light themes receive a luminous top edge.
    const shelf = Rect{ .x = dock.x, .y = dock.y + 7, .w = dock.w, .h = dock.h - 10 };
    dock_material.paintShadowed(s, shelf, 20, active_theme.dock, 185);
    if (active_theme.edge_highlights) s.rounded(.{ .x = shelf.x + 20, .y = shelf.y, .w = shelf.w - 40, .h = 1 }, 0, active_theme.rim, 115);
    s.rounded(.{ .x = dock.x + 410, .y = dock.y + 24, .w = 1, .h = 41 }, 0, 0x778397, 60);
    s.rounded(.{ .x = dock.x + 575, .y = dock.y + 24, .w = 1, .h = 41 }, 0, 0x778397, 60);
    var drawing = s.*;
    for (DOCK_ACTIONS, 0..) |action, i| {
        const r = dockItem(s, i);
        const hovered = state.hover == action;
        // Fixed optical size avoids abrupt magnification jumps on pointer entry.
        ui.icon(&drawing, DOCK_ICONS[i], r.x + 8, r.y + 3, 56);
        if (DOCK_APPS[i]) |app| if (state.running[app]) {
            s.circle(r.x + 36, r.y + 70, 2, INK);
        };
        if (hovered) {
            const tw = font.textWidth(LABELS[i], 1) + 24;
            const tag = Rect{ .x = r.x + @divTrunc(r.w - tw, 2), .y = dock.y - 40, .w = tw, .h = 28 };
            glass(s, tag, 8, 242);
            centered(s, LABELS[i], tag, INK);
        }
    }

    if (state.notice.len > 0) {
        const toast = Rect{ .x = @divTrunc(s.width - 400, 2), .y = dock.y - 88, .w = 400, .h = 36 };
        glass(s, toast, 12, 242);
        centered(s, state.notice, toast, INK);
    }
    if (state.popup == .none) return;
    const p = popupRect(s, state.popup);
    if (!Rect.overlaps(popupExtent(s, state.popup), s.clip)) return;
    const material_started = if (pulp.desktop_profile) pulp.uptimeMs() else 0;
    if (state.popup == .calendar) {
        glassMaterial(s, p, 18, 242, &calendar_material);
    } else {
        panel_material.paintShadowed(s, p, 18, active_theme.panel, 226);
        glassRim(s, p, 18);
    }
    const material_finished = if (pulp.desktop_profile) pulp.uptimeMs() else 0;
    switch (state.popup) {
        .menu => {
            text(s, "Orange OS", p.x + 18, p.y + 24, MUTED);
            const labels = [_][]const u8{ "Welcome to Orange", "New terminal", "All windows", "About Orange OS" };
            const actions = [_]u16{ Action.home, Action.new_terminal, Action.overview, Action.about };
            for (labels, 0..) |label, i| {
                const r = Rect{ .x = p.x + 12, .y = p.y + 56 + @as(i32, @intCast(i)) * 35, .w = p.w - 24, .h = 33 };
                if (state.hover == actions[i]) s.rounded(r, 7, active_theme.hover, 240);
                text(s, label, r.x + 10, r.y + 12, INK);
            }
        },
        .overview => {
            font.drawText(s, "Your workspace", p.x + 22, p.y + 24, 2, INK);
            text(s, "All your open windows, together.", p.x + 22, p.y + 62, MUTED);
            if (state.count == 0) text(s, "Open an app from the dock to get started.", p.x + 22, p.y + 116, INK);
            overview_base.capture(s, p);
            paintOverviewCards(s, state);
        },
        .settings => {
            font.drawText(s, "Appearance", p.x + 20, p.y + 25, 2, INK);
            text(s, "Choose your Orange OS theme", p.x + 20, p.y + 78, MUTED);
            const names = [_][]const u8{ "1 Coastal", "2 Citrus", "3 Aurora" };
            for (0..3) |i| {
                const r = paletteCard(s, i);
                s.rounded(.{ .x = r.x - 3, .y = r.y - 3, .w = r.w + 6, .h = r.h + 6 }, 10, if (state.palette == i) ACCENT else active_theme.muted, 255);
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
                centered(s, names[i], .{ .x = r.x, .y = r.bottom() + 10, .w = r.w, .h = 14 }, INK);
            }
            const button = Rect{ .x = p.x + 20, .y = p.y + 210, .w = 320, .h = 40 };
            s.rounded(button, 10, if (state.hover == Action.desktop) active_theme.hover else WHITE, 220);
            centered(s, "Show / restore desktop", button, ACCENT);
            s.rounded(.{ .x = p.x + 20, .y = p.y + 269, .w = 320, .h = 1 }, 0, active_theme.muted, 100);
            text(s, "Display & session", p.x + 20, p.y + 286, INK);
            var buffer: [64]u8 = undefined;
            const dimensions = @import("std").fmt.bufPrint(&buffer, "Display  {d} x {d}  /  {d}x UI", .{ s.width * s.scale, s.height * s.scale, s.scale }) catch "Display information unavailable";
            text(s, dimensions, p.x + 20, p.y + 311, MUTED);
            text(s, "Green button: zoom / restore", p.x + 20, p.y + 328, MUTED);
            text(s, "Theme choice resets on reboot.", p.x + 20, p.y + 358, MUTED);
            const hardware = hardwareButton(s);
            s.rounded(hardware, 10, if (state.hover == Action.hardware) active_theme.hover else WHITE, 220);
            ui.icon(s, .controls, hardware.x + 10, hardware.y + 8, 24);
            text(s, "Control Center", hardware.x + 46, hardware.y + 14, INK);
        },
        .calendar => {
            // Own a finished material layer before content. Hover/date updates
            // restore this layer, never recomposite the windows behind it.
            calendar_base.capture(s, p);
            const key = calendarKey(state);
            if (calendar_key != null and @import("std").meta.eql(calendar_key.?, key) and calendar_finished.restore(s)) {
                var content = s.*;
                content.setClip(Rect.intersect(s.clip, calendar_material.last_damage));
                _ = calendar_base.restore(&content);
                paintCalendar(&content, state);
                calendar_finished.refresh(&content);
            } else {
                paintCalendar(s, state);
                calendar_finished.capture(s, p);
            }
            calendar_key = key;
            if (pulp.desktop_profile) pulp.print("perf: calendar material {d}ms content {d}ms dirty {d}\n", .{ material_finished - material_started, pulp.uptimeMs() - material_finished, calendar_material.last_damage.w * calendar_material.last_damage.h });
        },
        .none => {},
    }
}

/// Compact observations, not connection claims: radio On does not mean an
/// internet link or paired device. Unknown/stale readings get a question mark.
fn paintHostStatus(s: *const Surface, state: *const State) void {
    if (s.width < 1160) return; // Preserve usable menus on narrower modes.
    const x = s.width - 472;
    for ([_]usize{ 0, 1, 3 }, [_]ui.Icon{ .wifi, .bluetooth, .speaker }, 0..) |row_index, icon, i| {
        const row = state.host.rows[row_index];
        const px = x + @as(i32, @intCast(i)) * 32;
        const unknown = state.host.connection != .fresh or row.reading == .status;
        const off = row.reading == .off or (row_index == 3 and (row.muted == true or (row.reading == .percent and row.reading.percent == 0)));
        ui.iconTint(s, icon, px, 4, 20, if (unknown or off) MUTED else INK);
        if (unknown) text(s, "?", px + 17, 10, MUTED) else if (off) text(s, "-", px + 17, 10, MUTED);
    }
    const battery = state.host.rows[4];
    ui.iconTint(s, if (battery.power == true and state.host.connection == .fresh) .battery else .battery_plain, x + 99, 3, 23, INK);
    var buf: [12]u8 = undefined;
    const value = if (state.host.connection == .fresh and battery.reading == .percent)
        @import("std").fmt.bufPrint(&buf, "{d}%", .{battery.reading.percent}) catch "?"
    else
        "?";
    text(s, value, x + 127, 10, INK);
}

fn hardwareButton(s: *const Surface) Rect {
    const p = popupRect(s, .settings);
    return .{ .x = p.x + 20, .y = p.y + 390, .w = 320, .h = 40 };
}
