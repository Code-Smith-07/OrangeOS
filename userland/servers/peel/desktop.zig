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
pub const spotlight = @import("spotlight.zig");
pub const menus = @import("menus.zig");
pub const notes = @import("notes.zig");

pub const BAR_H = 28;
pub const DOCK_H = 64;
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
    pub const browser: u16 = 19;
    pub const wallpaper: u16 = 20;
    pub const spotlight: u16 = 24;
    /// Appearance: the Reduce Motion switch.
    pub const reduce_motion: u16 = 25;
    pub const editor: u16 = 26;
    pub const viewer: u16 = 27;
    pub const calculator: u16 = 28;
    /// The Settings application (Action.settings is the quick Appearance panel).
    pub const settings_app: u16 = 29;
    pub const notifications: u16 = 30;
    pub const lock: u16 = 31;
    pub const clear_notes: u16 = 32;
    pub const banner: u16 = 33;
    /// Menu titles in the menu bar, then the items of the open menu.
    pub const app_menu: u16 = 40;
    pub const menu_item: u16 = 60;
    pub const window: u16 = 100;
    /// Spotlight result rows, then app-switcher tiles.
    pub const result: u16 = 200;
    pub const switch_item: u16 = 220;
};
comptime {
    const a = spotlight.actions;
    if (a.overview != Action.overview or a.settings != Action.settings or a.desktop != Action.desktop or
        a.new_terminal != Action.new_terminal or a.calendar != Action.calendar or a.wallpaper != Action.wallpaper or
        a.lock != Action.lock or a.notifications != Action.notifications)
        @compileError("spotlight.actions must mirror desktop.Action");
}
pub const Popup = enum { none, menu, overview, settings, calendar, spotlight, switcher, app_menu, notifications };
/// One tile in the Alt+Tab switcher: a window, most recently used first.
pub const SwitchItem = struct { id: u32 = 0, app: usize = 0, title: []const u8 = "", hidden: bool = false };
pub const Item = struct {
    id: u32 = 0,
    revision: u64 = 0,
    title: []const u8 = "",
    hidden: bool = false,
    app: usize = 0,
    pixels: ?[*]const u32 = null,
    width: i32 = 0,
    height: i32 = 0,
    /// Buffer pixels per row (a resizable window's buffer is wider).
    stride: i32 = 0,
};
pub const State = struct {
    popup: Popup = .none,
    hover: u16 = 0,
    palette: usize = 0,
    active: []const u8 = "Desktop",
    running: [APP_COUNT]bool = [_]bool{false} ** APP_COUNT,
    /// The front application's name and menus (its own, then Peel's Window
    /// menu), and which menu is open.
    app_name: []const u8 = "Desktop",
    bar: ?*const menus.Bar = null,
    open_menu: usize = 0,
    /// Notifications: the list, and the one shown as a banner now.
    notes: ?*const notes.Store = null,
    banner: ?*const notes.Note = null,
    lock: LockView = .{},
    items: [8]Item = [_]Item{.{}} ** 8,
    count: usize = 0,
    seconds: ?u64 = null,
    month_offset: i32 = 0,
    notice: []const u8 = "",
    host: host_model.Model = .{},
    controls_open: bool = false,
    /// Spotlight: what was typed, what it found, and the highlighted row.
    query: []const u8 = "",
    results: []const spotlight.Result = &.{},
    selected: usize = 0,
    /// Alt+Tab: the windows on offer and the highlighted one.
    switcher: []const SwitchItem = &.{},
    switch_selected: usize = 0,
    /// Preferences reach the /data disk (false: no data disk attached).
    prefs_kept: bool = false,
    /// No open or minimise motion.
    reduce_motion: bool = false,
};

pub const APP_COUNT = 12;
/// Names for the menu bar, by Peel's application index.
pub const APP_NAMES = [APP_COUNT][]const u8{ "Welcome", "Terminal", "Clock", "About", "Files", "Trash", "Control Center", "Orange Browser", "Text Editor", "Image Viewer", "Calculator", "Settings" };

/// What the lock screen shows. The password itself never reaches the
/// painter: only how many characters were typed.
pub const LockView = struct {
    active: bool = false,
    name: []const u8 = "",
    typed: usize = 0,
    message: []const u8 = "",
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
// The dock: apps, then Mission Control and Settings, then Trash.
const LABELS = [_][]const u8{ "Files", "Welcome", "Terminal", "Clock", "About", "Browser", "Text Editor", "Calculator", "Image Viewer", "Mission Control", "Settings", "Trash" };
const DOCK_ACTIONS = [_]u16{ Action.files, Action.home, Action.terminal, Action.clock, Action.about, Action.browser, Action.editor, Action.calculator, Action.viewer, Action.overview, Action.settings_app, Action.trash };
const DOCK_ICONS = [_]ui.Icon{ .dock_files, .dock_welcome, .dock_terminal, .dock_clock, .dock_about, .dock_browser, .dock_editor, .dock_calculator, .dock_viewer, .dock_windows, .dock_appearance, .dock_trash };
const DOCK_APPS = [_]?usize{ 4, 0, 1, 2, 3, 7, 8, 10, 9, null, 11, 5 };
const DOCK_W: i32 = 16 + 12 * 76 + 24;
// Clean assets derived from the three approved concepts. The BMP resources
// live on CitrusFS, not inside Peel's ELF (keeping the app binary lean).
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
    return .{ .x = @divTrunc(s.width - DOCK_W, 2), .y = s.height - DOCK_H - 14, .w = DOCK_W, .h = DOCK_H };
}
/// The dock slot showing an application (Peel's app index); Control
/// Center, which has no tile, uses Appearance's.
pub fn dockSlot(app: usize) usize {
    return ([APP_COUNT]usize{ 1, 2, 3, 4, 0, 11, 10, 5, 6, 8, 7, 10 })[@min(app, APP_COUNT - 1)];
}

/// The Reduce Motion switch: the measured macOS switch, 42 x 25 points.
pub fn motionSwitch(s: *const Surface) Rect {
    const p = popupRect(s, .settings);
    return .{ .x = p.right() - 20 - 42, .y = p.y + 320, .w = 42, .h = 25 };
}

pub fn dockItem(s: *const Surface, index: usize) Rect {
    const d = dockRect(s);
    return .{ .x = d.x + 16 + @as(i32, @intCast(index)) * 76 + (if (index >= 9) @as(i32, 12) else 0) + (if (index == 11) @as(i32, 12) else 0), .y = d.y + 8, .w = 72, .h = 54 };
}
pub fn popupRect(s: *const Surface, popup: Popup) Rect {
    return switch (popup) {
        .none => .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .menu => .{ .x = 8, .y = BAR_H + 4, .w = 250, .h = 12 + ORANGE_MENU.len * 28 + 12 },
        .app_menu => app_menu_rect,
        .notifications => .{ .x = s.width - 376, .y = BAR_H + 8, .w = 360, .h = 66 + @as(i32, @intCast(@max(1, note_rows))) * NOTE_H + 10 },
        .settings => .{ .x = s.width - 376, .y = 48, .w = 360, .h = 450 },
        .calendar => .{ .x = s.width - 376, .y = 48, .w = 360, .h = 438 },
        .overview => .{ .x = @divTrunc(s.width - 650, 2), .y = 92, .w = 650, .h = 428 },
        .spotlight => spotlightRect(s, spotlight_rows),
        .switcher => switcherRect(s, switcher_tiles),
    };
}

// The Orange menu, as the Apple menu: about, settings, and the session.
const OrangeItem = struct { label: []const u8, action: u16, gap: bool = false };
const ORANGE_MENU = [_]OrangeItem{
    .{ .label = "About Orange OS", .action = Action.about },
    .{ .label = "Settings...", .action = Action.settings_app, .gap = true },
    .{ .label = "Welcome", .action = Action.home },
    .{ .label = "New Terminal Window", .action = Action.new_terminal },
    .{ .label = "Mission Control", .action = Action.overview },
    .{ .label = "Lock Screen", .action = Action.lock, .gap = true },
};
fn orangeItem(s: *const Surface, i: usize) Rect {
    const p = popupRect(s, .menu);
    return .{ .x = p.x + 6, .y = p.y + 12 + @as(i32, @intCast(i)) * 28, .w = p.w - 12, .h = 24 };
}

// ── App menus (docs/design/014, M7) ───────────────────────────────────────
const MENU_ITEM_H: i32 = 24;
const MENU_GAP_H: i32 = 9;
var app_menu_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };

/// Where the app's name ends and its menu titles begin.
fn menuStart(s: *const Surface, state: *const State) i32 {
    return 46 + font.menuWidth(state.app_name, s.scale) + 12;
}
/// Menu title `i` in the menu bar.
pub fn menuTitle(s: *const Surface, state: *const State, i: usize) Rect {
    const bar = state.bar orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    var x = menuStart(s, state);
    for (bar.menus[0..bar.count], 0..) |m, k| {
        const w = font.menuWidth(m.title, s.scale) + 18;
        if (k == i) return .{ .x = x, .y = 2, .w = w, .h = BAR_H - 4 };
        x += w;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}
/// The open menu's panel, under its title. Call when a menu opens.
pub fn layoutAppMenu(s: *const Surface, state: *const State) void {
    const bar = state.bar orelse return;
    if (state.open_menu >= bar.count) return;
    const m = &bar.menus[state.open_menu];
    var w: i32 = 190;
    var h: i32 = 12;
    for (m.items[0..m.count]) |item| {
        h += if (item.separator) MENU_GAP_H else MENU_ITEM_H;
        const need = font.textWidth(item.label, 1) + 44 + (if (item.shortcut.len > 0) font.textWidth(item.shortcut, 1) + 28 else 0);
        w = @max(w, need);
    }
    const t = menuTitle(s, state, state.open_menu);
    app_menu_rect = .{ .x = @min(t.x, s.width - w - 8), .y = BAR_H + 2, .w = w, .h = h };
}
/// Item `j` of the open menu (separators are short rows).
pub fn appMenuItem(state: *const State, j: usize) Rect {
    const bar = state.bar orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const m = &bar.menus[@min(state.open_menu, bar.count -| 1)];
    var y = app_menu_rect.y + 6;
    for (m.items[0..m.count], 0..) |item, k| {
        const h: i32 = if (item.separator) MENU_GAP_H else MENU_ITEM_H;
        if (k == j) return .{ .x = app_menu_rect.x + 6, .y = y, .w = app_menu_rect.w - 12, .h = h };
        y += h;
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

// ── Notifications (M6) ─────────────────────────────────────────────────────
const NOTE_H: i32 = 58;
var note_rows: usize = 1;
/// How many notifications the list shows (set before it opens).
pub fn setNoteRows(n: usize) void {
    note_rows = @min(n, 7);
}
pub fn bellButton(s: *const Surface) Rect {
    return .{ .x = s.width - 246, .y = 2, .w = 28, .h = 24 };
}
/// The banner under the menu bar's right end.
pub fn bannerRect(s: *const Surface) Rect {
    return .{ .x = s.width - 376, .y = BAR_H + 10, .w = 360, .h = 64 };
}
fn clearButton(s: *const Surface) Rect {
    const p = popupRect(s, .notifications);
    return .{ .x = p.right() - 18 - 64, .y = p.y + 16, .w = 64, .h = 26 };
}

// Spotlight sits in the upper third, as on the Mac: one tall search field,
// then up to six 44-point result rows under a hairline.
pub const SPOTLIGHT_W: i32 = 640;
const FIELD_H: i32 = 56;
const ROW_H: i32 = 44;
var spotlight_rows: usize = 0;
var switcher_tiles: usize = 0;
/// Rows below the field: results, or one "No results" line. Peel damages
/// the old and new extents around a change.
pub fn setSpotlightRows(rows: usize) void {
    spotlight_rows = rows;
}
pub fn setSwitcherTiles(n: usize) void {
    switcher_tiles = n;
}
pub fn spotlightRect(s: *const Surface, rows: usize) Rect {
    const w = @min(SPOTLIGHT_W, s.width - 32);
    const list: i32 = if (rows == 0) 0 else 9 + @as(i32, @intCast(rows)) * ROW_H + 8;
    return .{ .x = @divTrunc(s.width - w, 2), .y = @max(BAR_H + 24, @divTrunc(s.height, 5)), .w = w, .h = FIELD_H + list };
}
pub fn spotlightRow(s: *const Surface, i: usize) Rect {
    const p = spotlightRect(s, spotlight_rows);
    return .{ .x = p.x + 8, .y = p.y + FIELD_H + 9 + @as(i32, @intCast(i)) * ROW_H, .w = p.w - 16, .h = ROW_H };
}
// The switcher: 112-point tiles holding 72-point icons, centred on screen.
const TILE: i32 = 112;
pub fn switcherRect(s: *const Surface, n: usize) Rect {
    const tiles: i32 = @intCast(@max(n, 1));
    const w = @min(s.width - 32, tiles * TILE + 32);
    const h: i32 = TILE + 32 + 34;
    return .{ .x = @divTrunc(s.width - w, 2), .y = @divTrunc(s.height - h, 2), .w = w, .h = h };
}
pub fn switcherTile(s: *const Surface, i: usize) Rect {
    const p = switcherRect(s, switcher_tiles);
    return .{ .x = p.x + 16 + @as(i32, @intCast(i)) * TILE, .y = p.y + 16, .w = TILE, .h = TILE };
}
/// The menu-bar magnifier that opens Spotlight.
pub fn searchButton(s: *const Surface) Rect {
    return .{ .x = s.width - 314, .y = 2, .w = 28, .h = 24 };
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
        if (searchButton(s).contains(x, y)) return Action.spotlight;
        if (bellButton(s).contains(x, y)) return Action.notifications;
        if (x < 40) return Action.menu;
        if (x >= s.width - 200) return Action.calendar;
        if (x >= s.width - (if (s.width >= 1160) @as(i32, 480) else 300)) return Action.hardware;
        if (state.bar) |bar| for (0..bar.count) |i| {
            if (menuTitle(s, state, i).contains(x, y)) return Action.app_menu + @as(u16, @intCast(i));
        };
        return Action.dismiss;
    }
    if (state.banner != null and state.popup != .notifications and bannerRect(s).contains(x, y)) return Action.banner;
    for (DOCK_ACTIONS, 0..) |action, i| {
        if (dockItem(s, i).contains(x, y)) return action;
    }
    if (dockRect(s).contains(x, y)) return Action.dismiss;
    if (state.popup != .none) {
        const p = popupRect(s, state.popup);
        if (!p.contains(x, y)) return Action.dismiss;
        switch (state.popup) {
            .menu => {
                for (ORANGE_MENU, 0..) |item, i| if (orangeItem(s, i).contains(x, y)) return item.action;
                return Action.keep_popup;
            },
            .app_menu => {
                if (state.bar) |bar| if (state.open_menu < bar.count) {
                    const m = &bar.menus[state.open_menu];
                    for (m.items[0..m.count], 0..) |item, j| {
                        if (item.enabled and !item.separator and appMenuItem(state, j).contains(x, y)) return Action.menu_item + @as(u16, @intCast(j));
                    }
                };
                return Action.keep_popup;
            },
            .notifications => {
                if (clearButton(s).contains(x, y)) return Action.clear_notes;
                return Action.keep_popup;
            },
            .overview => for (0..state.count) |i| {
                if (windowCard(s, i).contains(x, y)) return Action.window + @as(u16, @intCast(i));
            },
            .settings => {
                for (0..3) |i| if (paletteCard(s, i).contains(x, y)) return Action.wallpaper + @as(u16, @intCast(i));
                if ((Rect{ .x = p.x + 20, .y = p.y + 210, .w = 320, .h = 40 }).contains(x, y)) return Action.desktop;
                if (hardwareButton(s).contains(x, y)) return Action.hardware;
                if ((Rect{ .x = p.x + 20, .y = p.y + 316, .w = 320, .h = 33 }).contains(x, y)) return Action.reduce_motion;
                return Action.keep_popup;
            },
            .calendar => {
                for ([_]u16{ Action.previous_month, Action.next_month, Action.today, Action.clock }) |action| {
                    if (calendarButton(s, action).contains(x, y)) return action;
                }
                return Action.keep_popup;
            },
            .spotlight => {
                for (0..state.results.len) |i| if (spotlightRow(s, i).contains(x, y)) return Action.result + @as(u16, @intCast(i));
                return Action.keep_popup;
            },
            .switcher => {
                for (0..state.switcher.len) |i| if (switcherTile(s, i).contains(x, y)) return Action.switch_item + @as(u16, @intCast(i));
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
    if (state.banner != null) out = gfx.expandForGlass(out, gfx.shadowExtent(bannerRect(s)));
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
    if ((state.popup == .spotlight or state.popup == .switcher) and old != new and (old >= Action.result or new >= Action.result))
        damage = Rect.unionWith(damage, popupRect(s, state.popup));
    if ((state.popup == .app_menu or state.popup == .notifications) and old != new)
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
        if (item.pixels) |pixels| previews[i].paint(s, pixels, item.id, item.revision, item.width, item.height, item.stride, r.x + 12, r.y + 15);
        text(s, item.title[0..@min(26, item.title.len)], r.x + 98, r.y + 17, INK);
        text(s, if (item.hidden) "Minimized" else "Open window", r.x + 98, r.y + 40, MUTED);
    }
}

pub fn paint(s: *const Surface, state: *const State) void {
    activateTheme(state.palette);
    // Translucent top strip with only real, actionable menus/status.
    bar_material.paint(s, .{ .x = 0, .y = 0, .w = s.width, .h = BAR_H }, 0, active_theme.bar, 222);
    // The Orange menu, the front app's name, then its menus (M7).
    if (state.popup == .menu) s.rounded(.{ .x = 8, .y = 2, .w = 30, .h = BAR_H - 4 }, 5, INK, 26);
    ui.icon(s, .menu_brand, 13, 4, 20);
    font.drawMenu(s, state.app_name, 46, 10, INK);
    if (state.bar) |bar| for (bar.menus[0..bar.count], 0..) |m, i| {
        const r = menuTitle(s, state, i);
        if (state.popup == .app_menu and state.open_menu == i) s.rounded(r, 5, INK, 26);
        font.drawMenu(s, m.title, r.x + 9, 10, INK);
    };
    if (state.popup == .calendar) s.rounded(.{ .x = s.width - 204, .y = 3, .w = 194, .h = 22 }, 7, WHITE, 100);
    if (state.seconds) |seconds| {
        const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
        var date_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        var bar_buf: [64]u8 = undefined;
        const label = @import("std").fmt.bufPrint(&bar_buf, "{s}  {s}", .{ pulp.calendar.dateText(&date_buf, date), pulp.calendar.clockText(&time_buf, date) }) catch "";
        font.drawMenu(s, label, s.width - font.menuWidth(label, s.scale) - 18, 10, INK);
    } else font.drawMenu(s, "Clock unavailable", s.width - 180, 10, INK);
    if (state.popup == .spotlight) s.rounded(searchButton(s), 5, INK, 26);
    ui.iconTint(s, .menu_search, searchButton(s).x + 4, 4, 20, INK);
    if (state.popup == .notifications) s.rounded(bellButton(s), 5, INK, 26);
    ui.iconTint(s, .menu_bell, bellButton(s).x + 4, 4, 20, INK);
    if (state.notes) |store| if (store.unread > 0) {
        // An unread dot, in the accent colour.
        s.circle(bellButton(s).x + 20, 8, 3, ACCENT);
    };
    if (state.controls_open) s.rounded(.{ .x = s.width - 282, .y = 2, .w = 28, .h = 24 }, 5, INK, 26);
    ui.iconTint(s, .menu_controls, s.width - 278, 4, 20, INK);
    paintHostStatus(s, state);

    const dock = dockRect(s);
    // A translucent shelf; only light themes receive a luminous top edge.
    const shelf = Rect{ .x = dock.x, .y = dock.y + 7, .w = dock.w, .h = dock.h - 10 };
    dock_material.paintShadowed(s, shelf, 16, active_theme.dock, 165);
    if (active_theme.edge_highlights) s.rounded(.{ .x = shelf.x + 20, .y = shelf.y, .w = shelf.w - 40, .h = 1 }, 0, active_theme.rim, 115);
    s.rounded(.{ .x = dockItem(s, 9).x - 7, .y = dock.y + 17, .w = 1, .h = 31 }, 0, 0x778397, 60);
    s.rounded(.{ .x = dockItem(s, 11).x - 7, .y = dock.y + 17, .w = 1, .h = 31 }, 0, 0x778397, 60);
    var drawing = s.*;
    for (DOCK_ACTIONS, 0..) |action, i| {
        const r = dockItem(s, i);
        const hovered = state.hover == action;
        // Fixed optical size avoids abrupt magnification jumps on pointer entry.
        ui.icon(&drawing, DOCK_ICONS[i], r.x + 14, r.y + 3, 44);
        if (DOCK_APPS[i]) |app| if (state.running[app]) {
            s.circle(r.x + 36, r.y + 51, 1, INK);
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
    if (state.banner) |note| if (state.popup != .notifications) paintBanner(s, note);
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
            for (ORANGE_MENU, 0..) |item, i| {
                const r = orangeItem(s, i);
                const hot = state.hover == item.action;
                if (hot) s.rounded(r, 5, ACCENT, 255);
                text(s, item.label, r.x + 10, r.y + 8, if (hot) 0xFFFFFF else INK);
                if (item.gap) s.rounded(.{ .x = r.x + 8, .y = r.bottom() + 1, .w = r.w - 16, .h = 1 }, 0, MUTED, 60);
            }
        },
        .app_menu => if (state.bar) |bar| if (state.open_menu < bar.count) {
            const m = &bar.menus[state.open_menu];
            for (m.items[0..m.count], 0..) |item, j| {
                const r = appMenuItem(state, j);
                if (item.separator) {
                    s.rounded(.{ .x = r.x + 8, .y = r.y + 4, .w = r.w - 16, .h = 1 }, 0, MUTED, 70);
                    continue;
                }
                const hot = item.enabled and state.hover == Action.menu_item + @as(u16, @intCast(j));
                if (hot) s.rounded(r, 5, ACCENT, 255);
                const ink: u32 = if (hot) 0xFFFFFF else if (item.enabled) INK else gfx.lerp(MUTED, active_theme.panel, 110);
                text(s, item.label, r.x + 12, r.y + 8, ink);
                if (item.shortcut.len > 0) text(s, item.shortcut, r.right() - 12 - font.textWidth(item.shortcut, 1), r.y + 8, if (hot) 0xFFFFFF else MUTED);
            }
        },
        .notifications => {
            font.drawText(s, "Notifications", p.x + 18, p.y + 20, 1, INK);
            const store = state.notes;
            const count = if (store) |st| st.count else 0;
            if (count > 0) {
                const cb = clearButton(s);
                s.rounded(cb, 6, if (state.hover == Action.clear_notes) active_theme.hover else WHITE, 220);
                centered(s, "Clear", cb, ACCENT);
            }
            s.rounded(.{ .x = p.x + 18, .y = p.y + 52, .w = p.w - 36, .h = 1 }, 0, MUTED, 60);
            if (count == 0) {
                text(s, "No notifications", p.x + 18, p.y + 78, MUTED);
            } else for (store.?.items[0..@min(count, note_rows)], 0..) |*note, i| {
                paintNote(s, note, .{ .x = p.x + 10, .y = p.y + 60 + @as(i32, @intCast(i)) * NOTE_H, .w = p.w - 20, .h = NOTE_H - 6 }, false);
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
            text(s, "Reduce motion", p.x + 20, p.y + 337, INK);
            const sw = motionSwitch(s);
            const on = state.reduce_motion;
            // Track: one solid colour, a glossy knob with a soft shadow.
            s.rounded(sw, 12, if (on) ACCENT else gfx.lerp(active_theme.muted, WHITE, 120), 255);
            s.rounded(.{ .x = sw.x + 1, .y = sw.y + 1, .w = sw.w - 2, .h = 6 }, 5, WHITE, if (on) 40 else 70);
            const knob_x = if (on) sw.right() - 23 else sw.x + 2;
            s.rounded(.{ .x = knob_x, .y = sw.y + 3, .w = 21, .h = 21 }, 10, 0x000000, 30);
            s.rounded(.{ .x = knob_x, .y = sw.y + 2, .w = 21, .h = 21 }, 10, WHITE, 255);
            text(s, if (state.prefs_kept) "Your choices are kept after a restart." else "No data disk: choices reset on restart.", p.x + 20, p.y + 361, MUTED);
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
        .spotlight => paintSpotlight(s, state, p),
        .switcher => paintSwitcher(s, state, p),
        .none => {},
    }
}

fn appIcon(app: u32) ui.Icon {
    return DOCK_ICONS[dockSlot(app)];
}

/// One notification: its app's icon, title, body and time. Long text is
/// cut to fit the card; nothing is drawn outside it.
fn paintNote(s: *const Surface, note: *const notes.Note, r: Rect, card: bool) void {
    if (!card) s.rounded(r, 10, WHITE, 150);
    var icons = s.*;
    ui.icon(&icons, appIcon(note.app), r.x + 10, r.y + @divTrunc(r.h - 32, 2), 32);
    var when: []const u8 = "";
    var time_buf: [32]u8 = undefined;
    if (note.at != 0) when = pulp.calendar.clockText(&time_buf, pulp.calendar.fromEpoch(note.at, pulp.timezone_minutes));
    // "5:55:06 AM" -> "5:55 AM": seconds are noise in a list.
    var short_buf: [16]u8 = undefined;
    if (when.len >= 10) {
        const colon = @import("std").mem.lastIndexOfScalar(u8, when, ':') orelse when.len;
        const tail = when[@min(when.len, colon + 3)..];
        when = @import("std").fmt.bufPrint(&short_buf, "{s}{s}", .{ when[0..colon], tail }) catch when;
    }
    const tw = font.textWidth(when, 1);
    const room = r.w - 54 - 12;
    text(s, ui.fitting(note.title(), room - tw - 10), r.x + 52, r.y + 12, INK);
    text(s, when, r.right() - 12 - tw, r.y + 12, MUTED);
    text(s, ui.fitting(note.body(), room), r.x + 52, r.y + 31, MUTED);
}

fn paintBanner(s: *const Surface, note: *const notes.Note) void {
    const r = bannerRect(s);
    if (!Rect.overlaps(gfx.shadowExtent(r), s.clip)) return;
    banner_material.paintShadowed(s, r, 16, active_theme.panel, 232);
    glassRim(s, r, 16);
    paintNote(s, note, .{ .x = r.x, .y = r.y + 4, .w = r.w, .h = r.h - 8 }, true);
}
var banner_material: gfx.FrostCache(120_000) = .{};

/// The lock screen (M8), drawn over the wallpaper the caller has painted:
/// the time, who is signed in, and a password field that shows only dots.
pub fn paintLock(s: *const Surface, state: *const State) void {
    activateTheme(state.palette);
    const full = Rect{ .x = 0, .y = 0, .w = s.width, .h = s.height };
    s.rounded(full, 0, 0x0A1020, 96);
    if (state.seconds) |seconds| {
        const date = pulp.calendar.fromEpoch(seconds, pulp.timezone_minutes);
        var date_buf: [32]u8 = undefined;
        var time_buf: [32]u8 = undefined;
        const day = pulp.calendar.dateText(&date_buf, date);
        var clock = pulp.calendar.clockText(&time_buf, date);
        // Hours and minutes only: a lock screen is read at a glance.
        if (@import("std").mem.lastIndexOfScalar(u8, clock, ':')) |colon| clock = clock[0..colon];
        font.drawText(s, day, @divTrunc(s.width - font.textWidth(day, 2), 2), @divTrunc(s.height, 7), 2, 0xFFFFFF);
        font.drawText(s, clock, @divTrunc(s.width - font.textWidth(clock, 4), 2), @divTrunc(s.height, 7) + 44, 4, 0xFFFFFF);
    }
    const cx = @divTrunc(s.width, 2);
    const top = @divTrunc(s.height * 55, 100);
    // Avatar: one accent colour, a darker rim and a soft top reflection.
    s.circle(cx, top, 44, gfx.lerp(ACCENT, 0x000000, 60));
    s.circle(cx, top, 42, ACCENT);
    s.rounded(.{ .x = cx - 26, .y = top - 38, .w = 52, .h = 20 }, 10, 0xFFFFFF, 40);
    ui.iconTint(s, .sym_user, cx - 26, top - 26, 52, 0xFFFFFF);
    const name = ui.fitting(state.lock.name, 300);
    font.drawText(s, name, cx - @divTrunc(font.textWidth(name, 1), 2), top + 60, 1, 0xFFFFFF);
    const field = lockField(s);
    s.rounded(field, 15, 0xFFFFFF, 64);
    s.rounded(.{ .x = field.x + 1, .y = field.y + 1, .w = field.w - 2, .h = field.h - 2 }, 14, 0x0A1020, 70);
    if (state.lock.typed == 0) {
        const hint = "Enter Password";
        font.drawText(s, hint, cx - @divTrunc(font.textWidth(hint, 1), 2), field.y + 11, 1, 0xC9D2E0);
    } else {
        const shown: i32 = @intCast(@min(state.lock.typed, 18));
        const start = cx - @divTrunc(shown * 11, 2) + 5;
        var i: i32 = 0;
        while (i < shown) : (i += 1) s.circle(start + i * 11, field.y + 15, 3, 0xFFFFFF);
    }
    const hint = if (state.lock.message.len > 0) state.lock.message else "Press Return to unlock";
    font.drawText(s, hint, cx - @divTrunc(font.textWidth(hint, 1), 2), field.bottom() + 16, 1, if (state.lock.message.len > 0) 0xFFD0C8 else 0xC9D2E0);
}
pub fn lockField(s: *const Surface) Rect {
    return .{ .x = @divTrunc(s.width, 2) - 110, .y = @divTrunc(s.height * 55, 100) + 86, .w = 220, .h = 30 };
}
/// What changes while typing: the field and the line under it.
pub fn lockTypingRect(s: *const Surface) Rect {
    const f = lockField(s);
    return .{ .x = f.x - 60, .y = f.y - 4, .w = f.w + 120, .h = f.h + 44 };
}

fn glyphIcon(g: spotlight.Glyph) ui.Icon {
    return switch (g) {
        .editor => .dock_editor,
        .viewer => .dock_viewer,
        .settings => .dock_appearance,
        .lock => .sym_lock,
        .document => .document,
        .folder => .folder_orange,
        .image => .image_file,
        .files => .dock_files,
        .welcome => .dock_welcome,
        .terminal => .dock_terminal,
        .clock, .calendar => .dock_clock,
        .about => .dock_about,
        .browser => .dock_browser,
        .controls => .controls,
        .trash => .dock_trash,
        .appearance => .dock_appearance,
        .windows, .desktop => .dock_windows,
        .calculator => .dock_calculator,
    };
}

/// Spotlight glyph for one of Peel's application indices.
pub fn appGlyph(app: usize) spotlight.Glyph {
    return switch (app) {
        0 => .welcome,
        1 => .terminal,
        2 => .clock,
        3 => .about,
        4 => .files,
        5 => .trash,
        6 => .controls,
        8 => .editor,
        9 => .viewer,
        10 => .calculator,
        11 => .settings,
        else => .browser,
    };
}

/// Text that fits `width`: whole when it fits, otherwise cut at a character
/// boundary with "..." (only window titles and long queries reach this).
fn fitted(buf: *[64]u8, str: []const u8, width: i32, size: i32) []const u8 {
    if (font.textWidth(str, size) <= width) return str;
    var n = @min(str.len, buf.len - 3);
    while (n > 0) : (n -= 1) {
        @memcpy(buf[0..n], str[0..n]);
        @memcpy(buf[n .. n + 3], "...");
        if (font.textWidth(buf[0 .. n + 3], size) <= width) return buf[0 .. n + 3];
    }
    return "";
}

fn paintSpotlight(s: *const Surface, state: *const State, p: Rect) void {
    // The field: magnifier, then the query (or a quiet placeholder) and a caret.
    ui.iconTint(s, .search, p.x + 18, p.y + 16, 24, MUTED);
    const text_x = p.x + 54;
    const room = p.w - 54 - 20;
    var buf: [64]u8 = undefined;
    if (state.query.len == 0) {
        font.drawText(s, "Spotlight Search", text_x, p.y + 18, 2, MUTED);
        s.rounded(.{ .x = text_x - 1, .y = p.y + 15, .w = 2, .h = 26 }, 1, ACCENT, 255);
    } else {
        // Keep the end of a long query (where the caret is) in view.
        var shown = state.query;
        while (shown.len > 1 and font.textWidth(shown, 2) > room - 6) shown = shown[1..];
        font.drawText(s, shown, text_x, p.y + 18, 2, INK);
        s.rounded(.{ .x = text_x + font.textWidth(shown, 2) + 2, .y = p.y + 15, .w = 2, .h = 26 }, 1, ACCENT, 255);
    }
    if (spotlight_rows == 0) return;
    s.rounded(.{ .x = p.x, .y = p.y + FIELD_H, .w = p.w, .h = 1 }, 0, active_theme.muted, 70);
    if (state.results.len == 0) {
        const r = spotlightRow(s, 0);
        text(s, "No results", r.x + 14, r.y + 18, MUTED);
        return;
    }
    for (state.results, 0..) |result, i| {
        const r = spotlightRow(s, i);
        const chosen = i == state.selected;
        const hovered = state.hover == Action.result + i;
        if (chosen) s.rounded(r, 8, ACCENT, 255) else if (hovered) s.rounded(r, 8, active_theme.hover, 200);
        ui.icon(s, glyphIcon(result.glyph), r.x + 10, r.y + 7, 30);
        const title_color: u32 = if (chosen) 0xFFFFFF else INK;
        const sub_color: u32 = if (chosen) 0xE6F0FF else MUTED;
        const hint: []const u8 = switch (result.kind) {
            .calculation => "",
            .window => "Switch",
            else => "Open",
        };
        const hint_w = if (chosen and hint.len > 0) font.textWidth(hint, 1) + 16 else 0;
        const width = r.w - 52 - 12 - hint_w;
        text(s, fitted(&buf, result.title, width, 1), r.x + 52, r.y + 9, title_color);
        var sub_buf: [64]u8 = undefined;
        text(s, fitted(&sub_buf, result.subtitle, width, 1), r.x + 52, r.y + 26, sub_color);
        if (hint_w > 0) text(s, hint, r.right() - hint_w + 4, r.y + 18, sub_color);
    }
}

fn switcherIcon(app: usize) ui.Icon {
    return switch (app) {
        0 => .welcome,
        1 => .terminal,
        2 => .clock,
        3 => .about,
        4 => .files,
        5 => .trash,
        8 => .app_editor,
        9 => .app_viewer,
        10 => .app_calculator,
        11 => .appearance,
        else => .app_browser,
    };
}

fn paintSwitcher(s: *const Surface, state: *const State, p: Rect) void {
    for (state.switcher, 0..) |item, i| {
        const r = switcherTile(s, i);
        if (i == state.switch_selected) s.rounded(.{ .x = r.x + 4, .y = r.y + 4, .w = r.w - 8, .h = r.h - 8 }, 18, INK, 34);
        ui.icon(s, switcherIcon(item.app), r.x + 20, r.y + 20, 72);
        if (item.hidden) s.circle(r.x + @divTrunc(r.w, 2), r.bottom() - 9, 2, MUTED);
    }
    if (state.switch_selected < state.switcher.len) {
        var buf: [64]u8 = undefined;
        const title = fitted(&buf, state.switcher[state.switch_selected].title, p.w - 32, 1);
        centered(s, title, .{ .x = p.x, .y = p.bottom() - 36, .w = p.w, .h = 20 }, INK);
    }
}

/// Compact observations, not connection claims: radio On does not mean an
/// internet link or paired device. Unknown/stale readings get a question mark.
fn paintHostStatus(s: *const Surface, state: *const State) void {
    if (s.width < 1160) return; // Preserve usable menus on narrower modes.
    const x = s.width - 472;
    for ([_]usize{ 0, 1, 3 }, [_]ui.Icon{ .menu_wifi, .menu_bluetooth, .menu_speaker }, 0..) |row_index, icon, i| {
        const row = state.host.rows[row_index];
        const px = x + @as(i32, @intCast(i)) * 32;
        const unknown = state.host.connection != .fresh or row.reading == .status;
        const off = row.reading == .off or (row_index == 3 and (row.muted == true or (row.reading == .percent and row.reading.percent == 0)));
        ui.iconTint(s, icon, px, 4, 20, if (unknown or off) MUTED else INK);
        if (unknown) font.drawMenu(s, "?", px + 17, 10, MUTED) else if (off) font.drawMenu(s, "-", px + 17, 10, MUTED);
    }
    const battery = state.host.rows[4];
    ui.iconTint(s, if (battery.power == true and state.host.connection == .fresh) .menu_battery else .menu_battery_plain, x + 99, 3, 23, INK);
    var buf: [12]u8 = undefined;
    const value = if (state.host.connection == .fresh and battery.reading == .percent)
        @import("std").fmt.bufPrint(&buf, "{d}%", .{battery.reading.percent}) catch "?"
    else
        "?";
    font.drawMenu(s, value, x + 127, 10, INK);
}

fn hardwareButton(s: *const Surface) Rect {
    const p = popupRect(s, .settings);
    return .{ .x = p.x + 20, .y = p.y + 390, .w = 320, .h = 40 };
}
