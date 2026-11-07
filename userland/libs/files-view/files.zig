//! Read-only file browsing and Trash-folder inspection through the real VFS.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
const model = @import("model.zig");
const keymap = @import("keymap");
var win: libpeel.Window = undefined;
// Keep unfinished toolbar/sidebar/list painting off the shared client surface.
// Sized for the largest window (the buffer's capacity), so a resize never
// reallocates.
var staging: []u32 = &.{};
var path_buf: [256]u8 = undefined;
var path_len: usize = 1;
var entries: [256]pulp.DirEntry = undefined;
var all_entries: [256]pulp.DirEntry = undefined;
var total: usize = 0;
var query: [16]u8 = undefined;
var query_len: usize = 0;
var search_active = false;
var selected: ?usize = null;
var ctrl_down = false;
var left_shift = false;
var right_shift = false;
var count: usize = 0;
var listing_capped = false;
var page: usize = 0;
var history: [16][256]u8 = undefined;
var history_len: [16]usize = undefined;
var history_count: usize = 0;
var message: []const u8 = "";
var preview: [65536]u8 = undefined;
var preview_len: usize = 0;
var preview_page: usize = 0;
var preview_lines: usize = 0;
var preview_capped = false;
var preview_name: [128]u8 = undefined;
var preview_name_len: usize = 0;
var preview_open = false;
var binary = false;
var pointer: ui.Pointer = .{};
var grid_view = true;

// ── Layout (docs/design/014, M2): everything follows the window size ──────
// A Finder-style toolbar window: the sidebar runs to the top edge under the
// window buttons, the toolbar is the measured 52 points, and the grid or
// list fits as many items as the content area holds.
const SIDEBAR_W: i32 = 180;
const BAR: i32 = ui.Metrics.toolbar_h;
const MIN_W: i32 = 560;
const MIN_H: i32 = 360;
const TILE_W: i32 = 118;
const TILE_H: i32 = 137;
const ROW_PITCH: i32 = 35;

/// Where items go: right of the sidebar, under the toolbar, above the path
/// line and status bar.
fn contentArea() ui.Rect {
    return .{ .x = SIDEBAR_W, .y = BAR + 16, .w = win.width - SIDEBAR_W, .h = win.height - 75 - (BAR + 16) };
}
fn columns() usize {
    if (!grid_view) return 1;
    return @intCast(@max(1, @divTrunc(contentArea().w - 16, TILE_W)));
}
fn rowsShown() usize {
    const c = contentArea();
    return @intCast(@max(1, if (grid_view) @divTrunc(c.h + 21, TILE_H) else @divTrunc(c.h, ROW_PITCH)));
}
/// Items on one page.
fn perPage() usize {
    return columns() * rowsShown();
}
fn entryRect(index: usize) ui.Rect {
    const slot = index % perPage();
    const c = contentArea();
    if (!grid_view) return .{ .x = c.x + 16, .y = c.y + 1 + @as(i32, @intCast(slot)) * ROW_PITCH, .w = c.w - 32, .h = 32 };
    const cols = columns();
    const left = c.x + @divTrunc(c.w - @as(i32, @intCast(cols)) * TILE_W + 6, 2);
    return .{ .x = left + @as(i32, @intCast(slot % cols)) * TILE_W, .y = c.y + @as(i32, @intCast(slot / cols)) * TILE_H, .w = 112, .h = 116 };
}
fn backButton() ui.Rect {
    return .{ .x = SIDEBAR_W + 16, .y = 12, .w = 32, .h = 28 };
}
fn upButton() ui.Rect {
    return .{ .x = SIDEBAR_W + 56, .y = 12, .w = 32, .h = 28 };
}
fn viewControl() ui.Rect {
    return .{ .x = win.width - 16 - 64, .y = 12, .w = 64, .h = 28 };
}
fn searchRect() ui.Rect {
    const w = @min(@as(i32, 180), @max(100, win.width - SIDEBAR_W - 340));
    return .{ .x = viewControl().x - 10 - w, .y = 15, .w = w, .h = ui.Metrics.search_h };
}
fn sidebarRow(i: usize) ui.Rect {
    return .{ .x = 10, .y = BAR + 24 + @as(i32, @intCast(i)) * 32, .w = SIDEBAR_W - 20, .h = 28 };
}
/// The preview panel and how many lines it shows per page.
fn previewBox() ui.Rect {
    const c = contentArea();
    return .{ .x = c.x + 18, .y = BAR + 90, .w = c.w - 36, .h = win.height - (BAR + 90) - 66 };
}
fn previewLines() usize {
    return @intCast(@max(1, @divTrunc(previewBox().h - 12, 18)));
}
fn pageButton(i: usize) ui.Rect {
    return .{ .x = win.width - 106 + @as(i32, @intCast(i)) * 50, .y = win.height - 45, .w = 42, .h = 27 };
}
fn entryIcon(index: usize) ui.Icon {
    const e = &entries[index];
    if (!e.isDir()) return .document;
    const name = e.nameSlice();
    if (std.mem.eql(u8, name, "Trash")) return .trash;
    return .files;
}

fn path() []const u8 {
    return path_buf[0..path_len];
}
fn trash() bool {
    return std.mem.eql(u8, path(), "/Trash");
}
fn filter() void {
    count = 0;
    for (all_entries[0..total]) |e| {
        if (!model.matches(e.nameSlice(), query[0..query_len])) continue;
        entries[count] = e;
        count += 1;
    }
    page = 0;
    selected = null;
    if (pulp.desktop_profile) pulp.print("files: filter '{s}': {d} matches\n", .{ query[0..query_len], count });
}
fn load() void {
    preview_open = false;
    page = 0;
    query_len = 0;
    search_active = false;
    selected = null;
    message = "";
    count = 0;
    while (count < entries.len) {
        const n = pulp.readdirPage(path(), entries[count..], count) catch {
            message = "This folder could not be read.";
            count = 0;
            total = 0;
            return;
        };
        count += n;
        if (n < 32) break;
    }
    var extra: [1]pulp.DirEntry = undefined;
    listing_capped = count == entries.len and (pulp.readdirPage(path(), &extra, count) catch 1) != 0;
    var visible: usize = 0;
    for (0..count) |i| {
        const name = entries[i].nameSlice();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        entries[visible] = entries[i];
        visible += 1;
    }
    count = visible;
    // Stable directories-first ordering.
    for (0..count) |i| {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = &entries[j - 1];
            const b = &entries[j];
            const before = if (a.isDir() != b.isDir()) b.isDir() else std.mem.order(u8, b.nameSlice(), a.nameSlice()) == .lt;
            if (!before) break;
            std.mem.swap(pulp.DirEntry, a, b);
        }
    }
    total = count;
    @memcpy(all_entries[0..total], entries[0..count]);
    pulp.print("files: listed {s}: {d} entries\n", .{ path(), count });
}
fn navigate(next: []const u8, remember: bool) void {
    if (next.len == 0 or next.len > path_buf.len) {
        message = "That path is too long.";
        return;
    }
    if (remember and !std.mem.eql(u8, next, path())) {
        if (history_count == history.len) {
            for (1..history.len) |i| {
                history[i - 1] = history[i];
                history_len[i - 1] = history_len[i];
            }
            history_count -= 1;
        }
        @memcpy(history[history_count][0..path_len], path());
        history_len[history_count] = path_len;
        history_count += 1;
    }
    @memcpy(path_buf[0..next.len], next);
    path_len = next.len;
    load();
}
fn openEntry(index: usize) void {
    if (index >= count) return;
    const e = &entries[index];
    var next: [256]u8 = undefined;
    const full = std.fmt.bufPrint(&next, "{s}{s}{s}", .{ path(), if (path_len == 1) "" else "/", e.nameSlice() }) catch {
        message = "That path is too long.";
        return;
    };
    if (e.isDir()) {
        navigate(full, true);
        return;
    }
    const fd = pulp.open(full) catch {
        message = "This file could not be opened.";
        return;
    };
    defer pulp.close(fd);
    preview_len = 0;
    while (preview_len < preview.len) {
        const n = pulp.read(@intCast(fd), preview[preview_len..@min(preview_len + 4096, preview.len)]) catch {
            message = "This file could not be read.";
            return;
        };
        if (n == 0) break;
        preview_len += n;
    }
    var extra: [1]u8 = undefined;
    preview_capped = preview_len == preview.len and (pulp.read(@intCast(fd), &extra) catch 1) != 0;
    preview_page = 0;
    preview_lines = model.lineCount(preview[0..preview_len]);
    search_active = false;
    preview_open = true;
    binary = false;
    message = "";
    preview_name_len = e.name_len;
    @memcpy(preview_name[0..preview_name_len], e.nameSlice());
    for (preview[0..preview_len]) |ch| {
        if ((ch < 32 and ch != '\n' and ch != '\r' and ch != '\t') or ch > 126) {
            binary = true;
            break;
        }
    }
    pulp.print("files: preview {s}, {d} bytes\n", .{ full, preview_len });
}
const MAX_TARGETS = 11 + 96;
fn targets(out: *[MAX_TARGETS]ui.Button) []const ui.Button {
    out[0] = .{ .id = 1, .rect = backButton() };
    out[1] = .{ .id = 2, .rect = upButton() };
    for (0..4) |i| out[2 + i] = .{ .id = @intCast(10 + i), .rect = sidebarRow(i) };
    out[6] = .{ .id = 20, .rect = pageButton(0) };
    out[7] = .{ .id = 21, .rect = pageButton(1) };
    out[8] = .{ .id = 30, .rect = ui.segment(viewControl(), 2, 0) };
    out[9] = .{ .id = 31, .rect = ui.segment(viewControl(), 2, 1) };
    out[10] = .{ .id = 32, .rect = searchRect() };
    var n: usize = 11;
    if (!preview_open) {
        const per = perPage();
        for (page * per..@min(count, (page + 1) * per, page * per + MAX_TARGETS - 11)) |i| {
            out[n] = .{ .id = @intCast(100 + i), .rect = entryRect(i) };
            n += 1;
        }
    }
    return out[0..n];
}
fn act(id: u32) bool {
    if (id == 1) {
        if (preview_open) {
            preview_open = false;
            return true;
        }
        if (history_count > 0) {
            history_count -= 1;
            navigate(history[history_count][0..history_len[history_count]], false);
            return true;
        }
    } else if (id == 2) {
        if (preview_open) {
            preview_open = false;
            return true;
        }
        if (path_len > 1) {
            var parent: [256]u8 = undefined;
            @memcpy(parent[0..path_len], path());
            const end = std.mem.lastIndexOfScalar(u8, path(), '/') orelse 0;
            navigate(parent[0..@max(1, end)], true);
            return true;
        }
    } else if (id >= 10 and id <= 13) {
        const next = ([_][]const u8{ "/", "/etc", "/bin", "/Trash" })[id - 10];
        if (!preview_open and std.mem.eql(u8, next, path())) return false;
        navigate(next, true);
        return true;
    } else if ((id == 20 or id == 21) and preview_open and !binary) {
        if (id == 20 and preview_page > 0) {
            preview_page -= 1;
        } else if (id == 21 and (preview_page + 1) * previewLines() < preview_lines) {
            preview_page += 1;
        } else return false;
        pulp.print("files: preview page {d}\n", .{preview_page + 1});
        return true;
    } else if (id == 20 and page > 0 and !preview_open) {
        page -= 1;
        selected = null;
        return true;
    } else if (id == 21 and (page + 1) * perPage() < count and !preview_open) {
        page += 1;
        selected = null;
        return true;
    } else if (id == 30 or id == 31) {
        const next = id == 30;
        if (next == grid_view) return false;
        const first = page * perPage();
        grid_view = next;
        page = first / perPage();
        pulp.print("files: view {s}\n", .{if (grid_view) "grid" else "list"});
        return true;
    } else if (id == 32 and !preview_open) {
        if (search_active) return false;
        search_active = true;
        return true;
    } else if (id >= 100 and id - 100 < count) {
        openEntry(id - 100);
        return true;
    }
    return false;
}

fn key(code: u16, down: bool) bool {
    if (code == keymap.CTRL) {
        ctrl_down = down;
        return false;
    }
    if (code == keymap.LSHIFT) {
        left_shift = down;
        return false;
    }
    if (code == keymap.RSHIFT) {
        right_shift = down;
        return false;
    }
    if (!down) return false;
    if (!preview_open and ((ctrl_down and code == 0x21) or code == 0x35)) {
        if (search_active) return false;
        search_active = true;
        return true;
    }
    if (code == keymap.ESC and !preview_open and (query_len > 0 or search_active)) {
        query_len = 0;
        search_active = false;
        filter();
        return true;
    }
    if (search_active) {
        if (code == keymap.ENTER or code == 0x50) {
            search_active = false;
            selected = if (count > 0) 0 else null;
            return true;
        }
        if (code == keymap.BACKSPACE) {
            if (query_len == 0) return false;
            query_len -= 1;
        } else {
            if (ctrl_down or code > 255 or query_len == query.len) return false;
            const ch = keymap.translate(@intCast(code), left_shift or right_shift);
            if (ch < 32 or ch > 126) return false;
            query[query_len] = ch;
            query_len += 1;
        }
        filter();
        return true;
    }
    if (code == keymap.BACKSPACE or code == keymap.ESC) return act(1);
    if (code == 0x49) return act(20); // Page Up
    if (code == 0x51) return act(21); // Page Down
    if (preview_open) {
        if (code == 0x48) return act(20);
        if (code == 0x50) return act(21);
        return false;
    }
    if (code == keymap.ENTER and selected != null) return act(@intCast(100 + selected.?));
    if (count == 0) return false;
    var next = selected orelse page * perPage();
    const step: usize = if (grid_view and (code == 0x48 or code == 0x50)) columns() else 1;
    if (code == 0x47) next = 0 else if (code == 0x4F) next = count - 1 else if (code == 0x48 or code == 0x4B) {
        if (selected != null) next -|= step;
    } else if (code == 0x50 or code == 0x4D) {
        if (selected != null) next = @min(count - 1, next + step);
    } else return false;
    if (selected == next) return false;
    selected = next;
    page = next / perPage();
    if (pulp.desktop_profile) pulp.print("files: selected {s}\n", .{entries[next].nameSlice()});
    return true;
}
fn centeredLabel(s: *ui.Surface, text: []const u8, y: i32, scale: i32, color: u32) void {
    const c = contentArea();
    const shown = ui.fitting(text, c.w - 24);
    ui.label(s, shown, c.x + @divTrunc(c.w - ui.textWidth(shown, scale), 2), y, scale, color);
}

fn paint(area: ui.Rect) void {
    var s = ui.surface(&win);
    s.pixels = staging.ptr;
    s.setClip(area);
    const W = win.width;
    const H = win.height;
    const T = ui.Tone;
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, 0xFFFFFF);
    // Sidebar, full height: the window buttons sit on its top.
    s.fill(.{ .x = 0, .y = 0, .w = SIDEBAR_W, .h = H }, T.sidebar);
    s.fill(.{ .x = SIDEBAR_W - 1, .y = 0, .w = 1, .h = H }, T.hairline);
    s.fill(.{ .x = SIDEBAR_W, .y = 0, .w = W - SIDEBAR_W, .h = BAR }, T.toolbar);
    s.fill(.{ .x = SIDEBAR_W, .y = BAR - 1, .w = W - SIDEBAR_W, .h = 1 }, T.hairline);
    for ([_]ui.Rect{ backButton(), upButton() }, 0..) |r, i| {
        const enabled = preview_open or (if (i == 0) history_count > 0 else path_len > 1);
        var st = ui.ControlState.of(pointer, @intCast(i + 1));
        st.enabled = enabled;
        ui.toolbarButton(&s, r, if (i == 0) .chevron_left else .chevron_up, st);
    }
    // The folder's name, between the buttons and the search field.
    const basename = if (path_len == 1) "Orange OS" else path()[(std.mem.lastIndexOfScalar(u8, path(), '/') orelse 0) + 1 ..];
    const title_x = upButton().right() + 14;
    ui.label(&s, ui.fitting(basename, searchRect().x - 10 - title_x), title_x, 22, 1, T.text);
    ui.searchField(&s, searchRect(), query[0..query_len], if (search_active) "Type to filter..." else "Search  Ctrl+F", search_active);
    const view = viewControl();
    const view_hover: ?usize = if (pointer.hover == 30) 0 else if (pointer.hover == 31) 1 else null;
    ui.segmented(&s, view, 2, if (grid_view) 0 else 1, view_hover);
    {
        const seg = ui.segment(view, 2, 0);
        for (0..4) |j| s.rounded(.{ .x = seg.x + 9 + @as(i32, @intCast(j % 2)) * 8, .y = 19 + @as(i32, @intCast(j / 2)) * 8, .w = 5, .h = 5 }, 1, if (grid_view) T.accent else T.symbol, 255);
        const seg2 = ui.segment(view, 2, 1);
        for (0..3) |j| s.rounded(.{ .x = seg2.x + 9, .y = 19 + @as(i32, @intCast(j)) * 6, .w = 14, .h = 2 }, 1, if (!grid_view) T.accent else T.symbol, 255);
    }
    ui.label(&s, "Favourites", 18, BAR + 8, 1, T.secondary);
    const names = [_][]const u8{ "Orange OS", "System", "Applications", "Trash" };
    const paths = [_][]const u8{ "/", "/etc", "/bin", "/Trash" };
    for (names, 0..) |name, i| {
        const r = sidebarRow(i);
        const active = std.mem.eql(u8, path(), paths[i]);
        if (active or pointer.hover == 10 + i) s.rounded(r, 5, if (pointer.pressed == 10 + i) 0xCAD8E8 else if (active) 0xDBE3ED else 0xE3E4E8, 255);
        ui.icon(&s, ([_]ui.Icon{ .sidebar_home, .sidebar_system, .sidebar_apps, .sidebar_trash })[i], r.x + 8, r.y + 5, 18);
        ui.label(&s, ui.fitting(name, r.w - 40), r.x + 33, r.y + 10, 1, 0x3D4046);
    }
    s.fill(.{ .x = 20, .y = H - 71, .w = SIDEBAR_W - 40, .h = 1 }, 0xDFE6EF);
    ui.label(&s, "CitrusFS", 20, H - 57, 1, 0x778397);
    ui.label(&s, "Read-only browsing", 20, H - 34, 1, 0x778397);
    const c = contentArea();
    if (!preview_open and !grid_view and count > 0) {
        ui.label(&s, "Name", c.x + 63, BAR + 4, 1, 0x7A7D84);
        ui.label(&s, "Kind", W - 80, BAR + 4, 1, 0x7A7D84);
    }
    if (message.len > 0) centeredLabel(&s, message, BAR + 91, 1, 0xB05251) else if (preview_open) {
        const box = previewBox();
        ui.label(&s, ui.fitting(preview_name[0..preview_name_len], box.w), box.x + 6, box.y - 30, 1, 0x253247);
        s.rounded(box, 10, 0xF4F7FB, 255);
        const lines = previewLines();
        if (binary) {
            ui.label(&s, "No text preview for this file.", box.x + 24, box.y + 42, 1, 0x556378);
            ui.label(&s, ui.fitting("Binary and non-ASCII files are not decoded yet.", box.w - 48), box.x + 24, box.y + 69, 1, 0x778397);
        } else {
            s.setClip(ui.Rect.intersect(area, .{ .x = box.x + 14, .y = box.y + 8, .w = box.w - 28, .h = box.h - 12 }));
            var pos: usize = 0;
            var row: usize = 0;
            while (pos < preview_len and row < (preview_page + 1) * lines) : (row += 1) {
                const span = model.lineAt(preview[0..preview_len], pos);
                pos = span.next;
                if (row < preview_page * lines) continue;
                var line: [model.COLUMNS]u8 = undefined;
                var used: usize = 0;
                for (preview[span.start..span.end]) |ch| {
                    if (ch == '\r') continue;
                    line[used] = if (ch == '\t') ' ' else ch;
                    used += 1;
                }
                ui.monoLabel(&s, line[0..used], box.x + 14, box.y + 16 + @as(i32, @intCast(row - preview_page * lines)) * 18, 0x556378);
            }
            s.setClip(area);
        }
        var status_buf: [96]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "{d} bytes{s} / Page {d} of {d}", .{ preview_len, if (preview_capped) " (64 KiB limit)" else "", preview_page + 1, @max(1, (preview_lines + lines - 1) / lines) }) catch "";
        ui.label(&s, ui.fitting(if (binary) "Binary preview unavailable" else status, pageButton(0).x - 16 - (c.x + 10)), c.x + 10, H - 36, 1, 0x778397);
        if (!binary and preview_page > 0) ui.icon(&s, .chevron_left, pageButton(0).x + 11, H - 42, 20);
        if (!binary and (preview_page + 1) * lines < preview_lines) ui.icon(&s, .chevron_right, pageButton(1).x + 11, H - 42, 20);
    } else if (count == 0) {
        ui.icon(&s, if (trash()) .trash else .files, c.x + @divTrunc(c.w - 86, 2), BAR + 79, 86);
        centeredLabel(&s, if (query_len > 0) "No matches" else if (trash()) "Trash is empty" else "An empty folder", BAR + 186, 2, 0x253247);
        centeredLabel(&s, if (query_len > 0) "Try another name. Esc clears the search." else if (trash()) "Nothing is stored in /Trash." else "There are no items to show here.", BAR + 232, 1, 0x778397);
        if (trash() and query_len == 0) {
            centeredLabel(&s, "Move, restore and permanent deletion", BAR + 281, 1, 0x778397);
            centeredLabel(&s, "are not supported by the filesystem API yet.", BAR + 303, 1, 0x778397);
        }
    } else {
        const per = perPage();
        for (page * per..@min(count, (page + 1) * per)) |i| {
            const r = entryRect(i);
            const name = entries[i].nameSlice();
            if (grid_view) {
                s.rounded(r, 11, if (selected == i or pointer.pressed == 100 + i) 0xDFEBFC else if (pointer.hover == 100 + i) 0xEDF4FD else 0xFFFFFF, if (selected == i or pointer.hover == 100 + i or pointer.pressed == 100 + i) 255 else 100);
                ui.icon(&s, entryIcon(i), r.x + 24, r.y + 8, 64);
                const shown = ui.fitting(name, 102);
                s.setClip(ui.Rect.intersect(area, .{ .x = r.x + 5, .y = r.y + 78, .w = 102, .h = 19 }));
                ui.label(&s, shown, r.x + @divTrunc(r.w - ui.textWidth(shown, 1), 2), r.y + 89, 1, 0x253247);
                s.setClip(area);
            } else {
                s.rounded(r, 7, if (selected == i or pointer.pressed == 100 + i) 0xDFEBFC else if (pointer.hover == 100 + i) 0xEDF4FD else if (i % 2 == 0) 0xF7F9FC else 0xFFFFFF, 255);
                ui.icon(&s, entryIcon(i), r.x + 10, r.y + 4, 25);
                s.setClip(ui.Rect.intersect(area, .{ .x = r.x + 47, .y = r.y, .w = r.w - 47 - 86, .h = 32 }));
                ui.label(&s, name, r.x + 47, r.y + 13, 1, 0x253247);
                s.setClip(area);
                ui.label(&s, if (entries[i].isDir()) "Folder" else "File", W - 80, r.y + 13, 1, 0x8994A5);
            }
        }
        var b: [64]u8 = undefined;
        s.setClip(ui.Rect.intersect(area, .{ .x = c.x + 10, .y = H - 80, .w = c.w - 20, .h = 24 }));
        ui.label(&s, path(), c.x + 10, H - 67, 1, 0x8A8D93);
        s.setClip(area);
        const status = std.fmt.bufPrint(&b, "{d}/{d} items{s} / Page {d}", .{ count, total, if (listing_capped) " (256 limit)" else "", page + 1 }) catch "";
        s.fill(.{ .x = c.x + 2, .y = H - 51, .w = c.w - 4, .h = 1 }, 0xEDF1F6);
        ui.label(&s, ui.fitting(status, pageButton(0).x - 16 - (c.x + 10)), c.x + 10, H - 36, 1, 0x778397);
        for (0..2) |i| {
            const id = 20 + i;
            if (pointer.hover == id) s.rounded(pageButton(i), 7, if (pointer.pressed == id) 0xDFEBFC else 0xEDF4FD, 255);
        }
        if (page > 0) ui.icon(&s, .chevron_left, pageButton(0).x + 11, H - 42, 20);
        if ((page + 1) * per < count) ui.icon(&s, .chevron_right, pageButton(1).x + 11, H - 42, 20);
    }
    ui.publishRegion(&win, staging, area);
    if (pulp.desktop_profile) pulp.puts("files: painted\n");
}

/// Peel asked for a new size: lay out again, draw all of it, then say so.
fn resize(payload: []const u8) void {
    if (!win.configure(payload)) return;
    // Keep the selection on screen at the new page size.
    if (selected) |sel| page = sel / perPage() else page = @min(page, if (count == 0) 0 else (count - 1) / perPage());
    if (preview_open) preview_page = @min(preview_page, if (preview_lines == 0) 0 else (preview_lines - 1) / previewLines());
    paint(.{ .x = 0, .y = 0, .w = win.width, .h = win.height });
    win.ackResize();
    if (pulp.desktop_profile) pulp.print("files: resized to {d}x{d}, {d} per page\n", .{ win.width, win.height, perPage() });
}

pub fn run(start_in_trash: bool) noreturn {
    const flags = libpeel.proto.WindowFlags;
    win = libpeel.open(.{
        .title = if (start_in_trash) "Trash" else "Files",
        .width = 680,
        .height = 450,
        .x = 260,
        .y = 170,
        .flags = flags.closable | flags.resizable | flags.full_size_content,
        .min_w = MIN_W,
        .min_h = MIN_H,
        .bar_height = BAR,
    }) catch pulp.exit(1);
    const bytes: usize = @intCast(win.stride * win.capacity_h * win.scale * 4);
    const memory = pulp.mapMemory(bytes, .read_write) catch pulp.exit(1);
    staging = @as([*]u32, @ptrCast(memory.ptr))[0 .. bytes / 4];
    navigate(if (start_in_trash) "/Trash" else "/", false);
    paint(.{ .x = 0, .y = 0, .w = win.width, .h = win.height });
    var buf: [128]u8 = undefined;
    while (true) {
        const previous = pointer;
        var content_changed = false;
        while (true) {
            const m = pulp.portRecvMsg(win.reply, &buf, false) catch break;
            if (m.len == 0) break;
            if (m.opcode == libpeel.proto.Op.close_requested) {
                win.destroy();
                pulp.exit(0);
            }
            if (m.opcode == libpeel.proto.Op.configure) {
                resize(buf[0..m.len]);
                continue;
            }
            if (m.opcode != libpeel.proto.Op.input or m.len < @sizeOf(libpeel.proto.Input)) continue;
            const ev: *align(1) const libpeel.proto.Input = @ptrCast(&buf);
            // Bit 1 marks an extended scancode even on key release.
            if (ev.kind == pulp.EV_KEY) content_changed = key(ev.code, ev.value & 1 != 0) or content_changed;
            if (ev.kind == pulp.EV_MOUSE) {
                var buttons: [MAX_TARGETS]ui.Button = undefined;
                const list = targets(&buttons);
                const press = ev.code & 1 != 0 and !pointer.down;
                const action = pointer.update(ev.x, ev.y, ev.code, list);
                // A press on the toolbar's empty background moves the window,
                // as dragging a title bar would.
                if (press and pointer.pressed == 0 and ev.y >= 0 and ev.y < BAR) win.requestMove();
                if (action != 0) content_changed = act(action) or content_changed;
            }
        }
        if (content_changed) {
            paint(.{ .x = 0, .y = 0, .w = win.width, .h = win.height });
        } else if (pointer.visualChanged(previous)) {
            var buttons: [MAX_TARGETS]ui.Button = undefined;
            for (targets(&buttons)) |t| {
                if ((previous.hover == t.id) == (pointer.hover == t.id) and (previous.pressed == t.id) == (pointer.pressed == t.id)) continue;
                // The view switcher redraws as one control.
                paint(if (t.id == 30 or t.id == 31) viewControl() else t.rect);
            }
        }
        pulp.sleepMs(16);
    }
}
