//! Read-only file browsing and Trash-folder inspection through the real VFS.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
var win: libpeel.Window = undefined;
// Keep unfinished toolbar/sidebar/list painting off the shared client surface.
var staging: [680 * 450 * 4]u32 = undefined;
var path_buf: [256]u8 = undefined;
var path_len: usize = 1;
var entries: [32]pulp.DirEntry = undefined;
var count: usize = 0;
var listing_capped = false;
var page: usize = 0;
var history: [16][256]u8 = undefined;
var history_len: [16]usize = undefined;
var history_count: usize = 0;
var message: []const u8 = "";
var preview: [4096]u8 = undefined;
var preview_len: usize = 0;
var preview_name: [128]u8 = undefined;
var preview_name_len: usize = 0;
var preview_open = false;
var binary = false;
var pointer: ui.Pointer = .{};
const ROWS = 8;
var grid_view = true;

fn entryRect(index: usize) ui.Rect {
    const slot = index % ROWS;
    if (!grid_view) return .{ .x = 182, .y = 73 + @as(i32, @intCast(slot)) * 35, .w = 476, .h = 32 };
    return .{ .x = 184 + @as(i32, @intCast(slot % 4)) * 118, .y = 72 + @as(i32, @intCast(slot / 4)) * 137, .w = 112, .h = 116 };
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
fn load() void {
    preview_open = false;
    page = 0;
    message = "";
    count = pulp.readdir(path(), &entries) catch {
        message = "This folder could not be read.";
        count = 0;
        return;
    };
    listing_capped = count == entries.len;
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
    preview_len = pulp.read(@intCast(fd), &preview) catch {
        message = "This file could not be read.";
        return;
    };
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
fn targets(out: *[18]ui.Button) []const ui.Button {
    out[0] = .{ .id = 1, .rect = .{ .x = 182, .y = 16, .w = 32, .h = 28 } };
    out[1] = .{ .id = 2, .rect = .{ .x = 222, .y = 16, .w = 32, .h = 28 } };
    for (0..4) |i| out[2 + i] = .{ .id = @intCast(10 + i), .rect = .{ .x = 10, .y = 42 + @as(i32, @intCast(i)) * 34, .w = 146, .h = 28 } };
    out[6] = .{ .id = 20, .rect = .{ .x = 574, .y = 405, .w = 42, .h = 27 } };
    out[7] = .{ .id = 21, .rect = .{ .x = 624, .y = 405, .w = 42, .h = 27 } };
    out[8] = .{ .id = 30, .rect = .{ .x = 510, .y = 16, .w = 28, .h = 28 } };
    out[9] = .{ .id = 31, .rect = .{ .x = 542, .y = 16, .w = 28, .h = 28 } };
    var n: usize = 10;
    if (!preview_open) {
        for (page * ROWS..@min(count, (page + 1) * ROWS)) |i| {
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
    } else if (id == 20 and page > 0 and !preview_open) {
        page -= 1;
        return true;
    } else if (id == 21 and (page + 1) * ROWS < count and !preview_open) {
        page += 1;
        return true;
    } else if (id == 30 or id == 31) {
        const next = id == 30;
        if (next == grid_view) return false;
        grid_view = next;
        pulp.print("files: view {s}\n", .{if (grid_view) "grid" else "list"});
        return true;
    } else if (id >= 100 and id - 100 < count) {
        openEntry(id - 100);
        return true;
    }
    return false;
}
fn paint(area: ui.Rect) void {
    var s = ui.surface(&win);
    s.pixels = &staging;
    s.setClip(area);
    s.fill(.{ .x = 0, .y = 0, .w = 680, .h = 450 }, 0xFFFFFF);
    s.fill(.{ .x = 0, .y = 0, .w = 166, .h = 450 }, 0xF0F0F2);
    s.fill(.{ .x = 165, .y = 0, .w = 1, .h = 450 }, 0xDDDEE1);
    s.fill(.{ .x = 166, .y = 0, .w = 514, .h = 56 }, 0xF8F8F9);
    s.fill(.{ .x = 166, .y = 55, .w = 514, .h = 1 }, 0xE1E2E5);
    for ([_]i32{ 182, 222 }, 0..) |x, i| {
        s.rounded(.{ .x = x, .y = 16, .w = 32, .h = 28 }, 7, if (pointer.pressed == i + 1) 0xDFEAF9 else if (pointer.hover == i + 1) 0xEBF1F8 else 0xF9FBFD, 255);
        const enabled = preview_open or (if (i == 0) history_count > 0 else path_len > 1);
        ui.iconTint(&s, if (i == 0) .chevron_left else .chevron_up, x + 6, 20, 20, if (enabled) 0x5C6067 else 0xBABDC2);
    }
    const basename = if (path_len == 1) "Orange OS" else path()[(std.mem.lastIndexOfScalar(u8, path(), '/') orelse 0) + 1 ..];
    s.setClip(ui.Rect.intersect(area, .{ .x = 273, .y = 14, .w = 220, .h = 30 }));
    ui.label(&s, basename, 273, 27, 1, 0x303238);
    s.setClip(area);
    for ([_]u32{ 30, 31 }, 0..) |id, index| {
        const x: i32 = if (index == 0) 510 else 542;
        const selected = (index == 0) == grid_view;
        s.rounded(.{ .x = x, .y = 16, .w = 28, .h = 28 }, 7, if (pointer.pressed == id) 0xCEDFF5 else if (selected) 0xDEEAFB else if (pointer.hover == id) 0xEDF3FA else 0xF9FBFD, 255);
        if (index == 0) {
            for (0..4) |j| s.rounded(.{ .x = x + 7 + @as(i32, @intCast(j % 2)) * 8, .y = 23 + @as(i32, @intCast(j / 2)) * 8, .w = 5, .h = 5 }, 1, if (selected) 0x397BE8 else 0x778397, 255);
        } else {
            for (0..3) |j| s.rounded(.{ .x = x + 7, .y = 23 + @as(i32, @intCast(j)) * 6, .w = 14, .h = 2 }, 1, if (selected) 0x397BE8 else 0x778397, 255);
        }
    }
    ui.label(&s, "Favourites", 18, 24, 1, 0x898B90);
    const names = [_][]const u8{ "Orange OS", "System", "Applications", "Trash" };
    const paths = [_][]const u8{ "/", "/etc", "/bin", "/Trash" };
    for (names, 0..) |name, i| {
        const y = 42 + @as(i32, @intCast(i)) * 34;
        const selected = std.mem.eql(u8, path(), paths[i]);
        if (selected or pointer.hover == 10 + i) s.rounded(.{ .x = 10, .y = y, .w = 146, .h = 28 }, 5, if (pointer.pressed == 10 + i) 0xCAD8E8 else if (selected) 0xDBE3ED else 0xE6E7E9, 255);
        ui.icon(&s, ([_]ui.Icon{ .sidebar_home, .sidebar_system, .sidebar_apps, .sidebar_trash })[i], 18, y + 5, 18);
        ui.label(&s, name, 43, y + 11, 1, 0x3D4046);
    }
    s.fill(.{ .x = 20, .y = 379, .w = 126, .h = 1 }, 0xDFE6EF);
    ui.label(&s, "CitrusFS", 20, 393, 1, 0x778397);
    ui.label(&s, "Read-only browsing", 20, 416, 1, 0x778397);
    if (!preview_open and !grid_view and count > 0) {
        ui.label(&s, "Name", 229, 64, 1, 0x7A7D84);
        ui.label(&s, "Kind", 600, 64, 1, 0x7A7D84);
    }
    if (message.len > 0) ui.label(&s, message, 198, 147, 1, 0xB05251) else if (preview_open) {
        ui.label(&s, preview_name[0..@min(preview_name_len, 48)], 190, 116, 1, 0x253247);
        s.rounded(.{ .x = 184, .y = 146, .w = 478, .h = 238 }, 10, 0xF4F7FB, 255);
        if (binary) {
            ui.label(&s, "No text preview for this file.", 208, 188, 1, 0x556378);
            ui.label(&s, "Binary and non-ASCII files are not decoded yet.", 208, 215, 1, 0x778397);
        } else {
            s.setClip(ui.Rect.intersect(area, .{ .x = 198, .y = 154, .w = 450, .h = 226 }));
            var line: [64]u8 = undefined;
            var used: usize = 0;
            var row: i32 = 0;
            for (preview[0..preview_len]) |ch| {
                if (ch == '\r') continue;
                if (ch == '\n' or used == 60) {
                    ui.label(&s, line[0..used], 198, 162 + row * 18, 1, 0x556378);
                    used = 0;
                    row += 1;
                    if (row == 12) break;
                    if (ch == '\n') continue;
                }
                line[used] = if (ch == '\t') ' ' else ch;
                used += 1;
            }
            if (row < 12 and used > 0) ui.label(&s, line[0..used], 198, 162 + row * 18, 1, 0x556378);
            s.setClip(area);
        }
        ui.label(&s, "Preview only: first 4 KiB / 12 lines", 190, 414, 1, 0x778397);
    } else if (count == 0) {
        ui.icon(&s, if (trash()) .trash else .files, 377, 135, 86);
        ui.label(&s, if (trash()) "Trash is empty" else "An empty folder", 318, 242, 2, 0x253247);
        ui.label(&s, if (trash()) "Nothing is stored in /Trash." else "There are no items to show here.", 302, 288, 1, 0x778397);
        if (trash()) {
            ui.label(&s, "Move, restore and permanent deletion", 273, 337, 1, 0x778397);
            ui.label(&s, "are not supported by the filesystem API yet.", 252, 359, 1, 0x778397);
        }
    } else {
        for (page * ROWS..@min(count, (page + 1) * ROWS)) |i| {
            const r = entryRect(i);
            const name = entries[i].nameSlice();
            if (grid_view) {
                s.rounded(r, 11, if (pointer.pressed == 100 + i) 0xDFEBFC else if (pointer.hover == 100 + i) 0xEDF4FD else 0xFFFFFF, if (pointer.hover == 100 + i or pointer.pressed == 100 + i) 255 else 100);
                ui.icon(&s, entryIcon(i), r.x + 24, r.y + 8, 64);
                const width = @min(@as(i32, 102), ui.textWidth(name[0..@min(name.len, 12)], 1));
                s.setClip(ui.Rect.intersect(area, .{ .x = r.x + 5, .y = r.y + 78, .w = 102, .h = 19 }));
                ui.label(&s, name[0..@min(name.len, 12)], r.x + @divTrunc(r.w - width, 2), r.y + 89, 1, 0x253247);
                s.setClip(area);
            } else {
                s.rounded(r, 7, if (pointer.pressed == 100 + i) 0xDFEBFC else if (pointer.hover == 100 + i) 0xEDF4FD else if (i % 2 == 0) 0xF7F9FC else 0xFFFFFF, 255);
                ui.icon(&s, entryIcon(i), 192, r.y + 4, 25);
                s.setClip(ui.Rect.intersect(area, .{ .x = 229, .y = r.y, .w = 355, .h = 32 }));
                ui.label(&s, name[0..@min(name.len, 42)], 229, r.y + 13, 1, 0x253247);
                s.setClip(area);
                ui.label(&s, if (entries[i].isDir()) "Folder" else "File", 600, r.y + 13, 1, 0x8994A5);
            }
        }
        var b: [64]u8 = undefined;
        s.setClip(ui.Rect.intersect(area, .{ .x = 190, .y = 370, .w = 460, .h = 24 }));
        ui.label(&s, path(), 190, 383, 1, 0x8A8D93);
        s.setClip(area);
        const status = std.fmt.bufPrint(&b, "{d} items{s}  /  Page {d}", .{ count, if (listing_capped) " (listing capped)" else "", page + 1 }) catch "";
        s.fill(.{ .x = 182, .y = 399, .w = 476, .h = 1 }, 0xEDF1F6);
        ui.label(&s, status, 190, 414, 1, 0x778397);
        for ([_]i32{ 574, 624 }, 0..) |x, i| {
            const id = 20 + i;
            if (pointer.hover == id) s.rounded(.{ .x = x, .y = 405, .w = 42, .h = 27 }, 7, if (pointer.pressed == id) 0xDFEBFC else 0xEDF4FD, 255);
        }
        if (page > 0) ui.icon(&s, .chevron_left, 585, 408, 20);
        if ((page + 1) * ROWS < count) ui.icon(&s, .chevron_right, 635, 408, 20);
    }
    ui.publishRegion(&win, &staging, area);
    if (pulp.desktop_profile) pulp.puts("files: painted\n");
}
pub fn run(start_in_trash: bool) noreturn {
    win = libpeel.createWindow(if (start_in_trash) "Trash" else "Files", 680, 450, 260, 170) catch pulp.exit(1);
    navigate(if (start_in_trash) "/Trash" else "/", false);
    const full = ui.Rect{ .x = 0, .y = 0, .w = 680, .h = 450 };
    paint(full);
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
            if (m.opcode != libpeel.proto.Op.input or m.len < @sizeOf(libpeel.proto.Input)) continue;
            const ev: *align(1) const libpeel.proto.Input = @ptrCast(&buf);
            if (ev.kind == pulp.EV_KEY and ev.value != 0 and (ev.code == 0x0E or ev.code == 0x01)) {
                if (ev.code == 0x0E or preview_open) {
                    content_changed = act(1) or content_changed;
                }
            }
            if (ev.kind == pulp.EV_MOUSE) {
                var buttons: [18]ui.Button = undefined;
                const action = pointer.update(ev.x, ev.y, ev.code, targets(&buttons));
                if (action != 0) content_changed = act(action) or content_changed;
            }
        }
        if (content_changed) {
            paint(full);
        } else if (pointer.visualChanged(previous)) {
            var buttons: [18]ui.Button = undefined;
            for (targets(&buttons)) |t| {
                if ((previous.hover == t.id) == (pointer.hover == t.id) and (previous.pressed == t.id) == (pointer.pressed == t.id)) continue;
                paint(t.rect);
            }
        }
        pulp.sleepMs(16);
    }
}
