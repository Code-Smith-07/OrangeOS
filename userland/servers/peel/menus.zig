//! Application menus (docs/design/014, M7). An app publishes its menus as
//! text (libpeel protocol.zig: `M<title>`, `I<id> <label>[\t<shortcut>]`,
//! `D...` for a disabled item, `-` for a separator); this file parses that
//! text, never trusting it, into what Peel draws in the menu bar. Peel adds
//! its own Window menu after the app's. Pure logic, unit tested.
const std = @import("std");

pub const MAX_MENUS = 6;
pub const MAX_ITEMS = 12;

pub const Item = struct {
    id: u32 = 0,
    label: []const u8 = "",
    shortcut: []const u8 = "",
    enabled: bool = true,
    separator: bool = false,
};

pub const Menu = struct {
    title: []const u8 = "",
    items: [MAX_ITEMS]Item = [_]Item{.{}} ** MAX_ITEMS,
    count: usize = 0,
};

pub const Bar = struct {
    menus: [MAX_MENUS + 1]Menu = [_]Menu{.{}} ** (MAX_MENUS + 1),
    count: usize = 0,
};

/// Item ids at or above this are Peel's own (the Window menu); an app's
/// ids are passed back to it unchanged and must be below it.
pub const SHELL_ID: u32 = 0xFFFF_0000;
pub const Shell = struct {
    pub const minimise: u32 = SHELL_ID + 1;
    pub const zoom: u32 = SHELL_ID + 2;
    pub const tile_left: u32 = SHELL_ID + 3;
    pub const tile_right: u32 = SHELL_ID + 4;
    pub const overview: u32 = SHELL_ID + 5;
    pub const show_desktop: u32 = SHELL_ID + 6;
    pub const close: u32 = SHELL_ID + 7;
};

fn printable(text: []const u8) bool {
    for (text) |c| if (c < 32 or c > 126) return false;
    return true;
}

/// Parse an app's menu text. Malformed lines are skipped, extra menus and
/// items are dropped, and labels are limited to 40 printable characters.
pub fn parse(text: []const u8) Bar {
    var bar = Bar{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r ");
        if (line.len == 0) continue;
        if (line[0] == 'M') {
            const title = line[1..];
            if (title.len == 0 or title.len > 20 or !printable(title) or bar.count == MAX_MENUS) continue;
            bar.menus[bar.count] = .{ .title = title };
            bar.count += 1;
            continue;
        }
        if (bar.count == 0) continue;
        const menu = &bar.menus[bar.count - 1];
        if (menu.count == MAX_ITEMS) continue;
        if (line[0] == '-') {
            // No leading or doubled separators.
            if (menu.count == 0 or menu.items[menu.count - 1].separator) continue;
            menu.items[menu.count] = .{ .separator = true, .enabled = false };
            menu.count += 1;
            continue;
        }
        if (line[0] != 'I' and line[0] != 'D') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const id = std.fmt.parseInt(u32, line[1..space], 10) catch continue;
        if (id == 0 or id >= SHELL_ID) continue;
        var rest = line[space + 1 ..];
        var shortcut: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '\t')) |tab| {
            shortcut = rest[tab + 1 ..];
            rest = rest[0..tab];
        }
        if (rest.len == 0 or rest.len > 40 or !printable(rest) or shortcut.len > 16 or !printable(shortcut)) continue;
        menu.items[menu.count] = .{ .id = id, .label = rest, .shortcut = shortcut, .enabled = line[0] == 'I' };
        menu.count += 1;
    }
    // A trailing separator has nothing under it.
    for (bar.menus[0..bar.count]) |*m| {
        if (m.count > 0 and m.items[m.count - 1].separator) m.count -= 1;
    }
    return bar;
}

/// Peel's Window menu, the same for every app; it acts on the front window.
pub fn windowMenu(has_window: bool, resizable: bool) Menu {
    var m = Menu{ .title = "Window" };
    const items = [_]Item{
        .{ .id = Shell.minimise, .label = "Minimise", .enabled = has_window },
        .{ .id = Shell.zoom, .label = "Zoom", .enabled = has_window },
        .{ .separator = true, .enabled = false },
        .{ .id = Shell.tile_left, .label = "Tile Left", .enabled = has_window and resizable },
        .{ .id = Shell.tile_right, .label = "Tile Right", .enabled = has_window and resizable },
        .{ .separator = true, .enabled = false },
        .{ .id = Shell.overview, .label = "Mission Control", .shortcut = "F3" },
        .{ .id = Shell.show_desktop, .label = "Show Desktop", .shortcut = "F11" },
        .{ .separator = true, .enabled = false },
        .{ .id = Shell.close, .label = "Close Window", .enabled = has_window },
    };
    for (items, 0..) |item, i| m.items[i] = item;
    m.count = items.len;
    return m;
}

const testing = std.testing;

test "an app's menus parse into titles, items, shortcuts and separators" {
    const bar = parse("MFile\nI1 New Folder\tCtrl+Shift+N\nI2 Rename\tF2\n-\nD3 Move to Trash\tDelete\nMView\nI10 as Icons\nI11 as List\n");
    try testing.expectEqual(@as(usize, 2), bar.count);
    try testing.expectEqualStrings("File", bar.menus[0].title);
    try testing.expectEqual(@as(usize, 4), bar.menus[0].count);
    try testing.expectEqualStrings("New Folder", bar.menus[0].items[0].label);
    try testing.expectEqualStrings("Ctrl+Shift+N", bar.menus[0].items[0].shortcut);
    try testing.expect(bar.menus[0].items[2].separator);
    try testing.expect(!bar.menus[0].items[3].enabled);
    try testing.expectEqual(@as(u32, 3), bar.menus[0].items[3].id);
    try testing.expectEqual(@as(u32, 11), bar.menus[1].items[1].id);
}

test "hostile menu text is skipped, never trusted" {
    // Items before any menu, bad ids, control characters, shell ids, long
    // labels, too many menus and items, stray separators.
    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    var text: [2048]u8 = undefined;
    var w = std.io.fixedBufferStream(&text);
    try w.writer().print("I1 Orphan\nMA\n-\n-\nIx Bad\nI0 Zero\nI{d} Shell\nI5 Bad\x07Bell\nI6 {s}\nI7 Fine\n-\n", .{ SHELL_ID + 1, long[0..60] });
    for (0..20) |i| try w.writer().print("I{d} Item\n", .{100 + i});
    for (0..10) |i| try w.writer().print("MM{d}\nI1 x\n", .{i});
    try w.writer().print("M{s}\n", .{long[0..40]});
    const bar = parse(w.getWritten());
    try testing.expectEqual(@as(usize, MAX_MENUS), bar.count);
    const a = bar.menus[0];
    try testing.expectEqualStrings("Fine", a.items[0].label);
    try testing.expect(a.items[1].separator);
    try testing.expectEqual(@as(usize, MAX_ITEMS), a.count);
    for (bar.menus[0..bar.count]) |m| for (m.items[0..m.count]) |item| {
        try testing.expect(item.separator or (item.id != 0 and item.id < SHELL_ID));
    };
    try testing.expectEqual(@as(usize, 0), parse("").count);
    try testing.expectEqual(@as(usize, 0), parse("-\n-\nI1 x").count);
}

test "the Window menu disables what has no window to act on" {
    const none = windowMenu(false, false);
    try testing.expect(!none.items[0].enabled and none.items[6].enabled);
    const fixed = windowMenu(true, false);
    try testing.expect(fixed.items[0].enabled and !fixed.items[3].enabled);
    try testing.expect(windowMenu(true, true).items[4].enabled);
}
