//! Read-only file browsing and Trash-folder inspection through the real VFS.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const ui = @import("ui");
var win: libpeel.Window = undefined;
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
fn targets(out: *[16]ui.Button) []const ui.Button {
    out[0] = .{ .id = 1, .rect = .{ .x = 18, .y = 16, .w = 32, .h = 28 } };
    out[1] = .{ .id = 2, .rect = .{ .x = 58, .y = 16, .w = 32, .h = 28 } };
    for (0..4) |i| out[2 + i] = .{ .id = @intCast(10 + i), .rect = .{ .x = 12, .y = 103 + @as(i32, @intCast(i)) * 42, .w = 140, .h = 34 } };
    out[6] = .{ .id = 20, .rect = .{ .x = 574, .y = 405, .w = 42, .h = 27 } };
    out[7] = .{ .id = 21, .rect = .{ .x = 624, .y = 405, .w = 42, .h = 27 } };
    var n: usize = 8;
    if (!preview_open) {
        for (page * ROWS..@min(count, (page + 1) * ROWS)) |i| {
            out[n] = .{ .id = @intCast(100 + i), .rect = .{ .x = 182, .y = 109 + @as(i32, @intCast(i % ROWS)) * 35, .w = 476, .h = 32 } };
            n += 1;
        }
    }
    return out[0..n];
}
fn act(id: u32) void {
    if (id == 1) {
        if (preview_open) {
            preview_open = false;
            return;
        }
        if (history_count > 0) {
            history_count -= 1;
            navigate(history[history_count][0..history_len[history_count]], false);
        }
    } else if (id == 2) {
        if (preview_open) {
            preview_open = false;
            return;
        }
        if (path_len > 1) {
            var parent: [256]u8 = undefined;
            @memcpy(parent[0..path_len], path());
            const end = std.mem.lastIndexOfScalar(u8, path(), '/') orelse 0;
            navigate(parent[0..@max(1, end)], true);
        }
    } else if (id >= 10 and id <= 13) navigate(([_][]const u8{ "/", "/etc", "/bin", "/Trash" })[id - 10], true) else if (id == 20 and page > 0 and !preview_open) {
        page -= 1;
    } else if (id == 21 and (page + 1) * ROWS < count and !preview_open) {
        page += 1;
    } else if (id >= 100) openEntry(id - 100);
}
fn paint() void {
    var s = ui.surface(&win);
    s.fill(.{ .x = 0, .y = 0, .w = 680, .h = 450 }, 0xFBFCFF);
    ui.gradient(&s, .{ .x = 0, .y = 0, .w = 166, .h = 450 }, 0, 0xEDEFF8, 0xE1E6F3);
    s.fill(.{ .x = 0, .y = 0, .w = 680, .h = 60 }, 0xF2F4FA);
    s.fill(.{ .x = 0, .y = 59, .w = 680, .h = 1 }, 0xE1E4ED);
    for ([_]i32{ 18, 58 }, 0..) |x, i| {
        s.rounded(.{ .x = x, .y = 16, .w = 32, .h = 28 }, 7, if (pointer.hover == i + 1) 0xDCE2F0 else 0xFFFFFF, 255);
        ui.icon(&s, if (i == 0) .chevron_left else .chevron_up, x + 6, 20, 20);
    }
    ui.label(&s, if (trash()) "Trash" else "Files", 111, 25, 1, 0x38405A);
    ui.label(&s, "FAVOURITES", 20, 78, 1, 0x8B94AA);
    const names = [_][]const u8{ "Orange OS", "System", "Applications", "Trash" };
    const paths = [_][]const u8{ "/", "/etc", "/bin", "/Trash" };
    for (names, 0..) |name, i| {
        const y = 103 + @as(i32, @intCast(i)) * 42;
        if (std.mem.eql(u8, path(), paths[i]) or pointer.hover == 10 + i) s.rounded(.{ .x = 12, .y = y, .w = 140, .h = 34 }, 8, 0xD0DCF5, 255);
        ui.icon(&s, if (i == 3) .trash else .files, 20, y + 7, 23);
        ui.label(&s, name, 52, y + 13, 1, 0x535F79);
    }
    ui.label(&s, "CITRUS FILESYSTEM", 20, 385, 1, 0x929BB0);
    ui.label(&s, "Read-only browsing", 20, 411, 1, 0x78849C);
    ui.label(&s, path()[0..@min(path_len, 62)], 184, 78, 1, 0x7E879B);
    if (message.len > 0) ui.label(&s, message, 198, 147, 1, 0xA05167) else if (preview_open) {
        ui.label(&s, preview_name[0..@min(preview_name_len, 48)], 190, 116, 1, 0x3D4660);
        s.rounded(.{ .x = 184, .y = 146, .w = 478, .h = 238 }, 10, 0xF0F3FA, 255);
        if (binary) {
            ui.label(&s, "No text preview for this file.", 208, 188, 1, 0x65718B);
            ui.label(&s, "Binary and non-ASCII files are not decoded yet.", 208, 215, 1, 0x929BB0);
        } else {
            s.setClip(.{ .x = 198, .y = 154, .w = 450, .h = 226 });
            var line: [64]u8 = undefined;
            var used: usize = 0;
            var row: i32 = 0;
            for (preview[0..preview_len]) |ch| {
                if (ch == '\r') continue;
                if (ch == '\n' or used == 60) {
                    ui.label(&s, line[0..used], 198, 162 + row * 18, 1, 0x56617A);
                    used = 0;
                    row += 1;
                    if (row == 12) break;
                    if (ch == '\n') continue;
                }
                line[used] = if (ch == '\t') ' ' else ch;
                used += 1;
            }
            if (row < 12 and used > 0) ui.label(&s, line[0..used], 198, 162 + row * 18, 1, 0x56617A);
            s.resetClip();
        }
        ui.label(&s, "Preview only: first 4 KiB / 12 lines", 190, 414, 1, 0x9199AC);
    } else if (count == 0) {
        ui.icon(&s, if (trash()) .trash else .files, 377, 135, 86);
        ui.label(&s, if (trash()) "Trash is empty" else "An empty folder", 318, 242, 2, 0x424C67);
        ui.label(&s, if (trash()) "Nothing is stored in /Trash." else "There are no items to show here.", 302, 288, 1, 0x8A94A9);
        if (trash()) {
            ui.label(&s, "Move, restore and permanent deletion", 273, 337, 1, 0x959DB0);
            ui.label(&s, "are not supported by the filesystem API yet.", 252, 359, 1, 0x959DB0);
        }
    } else {
        for (page * ROWS..@min(count, (page + 1) * ROWS)) |i| {
            const y = 109 + @as(i32, @intCast(i % ROWS)) * 35;
            s.rounded(.{ .x = 182, .y = y, .w = 476, .h = 32 }, 7, if (pointer.hover == 100 + i) 0xE4ECFC else if (i % 2 == 0) 0xF3F5FB else 0xFBFCFF, 255);
            ui.icon(&s, if (entries[i].isDir()) .files else .document, 190, y + 3, 27);
            const name = entries[i].nameSlice();
            s.setClip(.{ .x = 229, .y = y, .w = 355, .h = 32 });
            ui.label(&s, name[0..@min(name.len, 42)], 229, y + 13, 1, 0x56617A);
            s.resetClip();
            ui.label(&s, if (entries[i].isDir()) "Folder" else "File", 600, y + 13, 1, 0x9CA4B4);
        }
        var b: [64]u8 = undefined;
        const status = std.fmt.bufPrint(&b, "{d} items{s}  /  Page {d}", .{ count, if (listing_capped) " (listing capped)" else "", page + 1 }) catch "";
        ui.label(&s, status, 190, 414, 1, 0x929AAE);
        if (page > 0) ui.icon(&s, .chevron_left, 585, 408, 20);
        if ((page + 1) * ROWS < count) ui.icon(&s, .chevron_right, 635, 408, 20);
    }
    win.commitAll();
}
pub fn run(start_in_trash: bool) noreturn {
    win = libpeel.createWindow(if (start_in_trash) "Trash" else "Files", 680, 450, 260, 170) catch pulp.exit(1);
    navigate(if (start_in_trash) "/Trash" else "/", false);
    paint();
    var buf: [128]u8 = undefined;
    while (true) {
        var dirty = false;
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
                    act(1);
                    dirty = true;
                }
            }
            if (ev.kind == pulp.EV_MOUSE) {
                var buttons: [16]ui.Button = undefined;
                const old = pointer;
                const action = pointer.update(ev.x, ev.y, ev.code, targets(&buttons));
                if (action != 0) {
                    act(action);
                    dirty = true;
                }
                dirty = dirty or old.hover != pointer.hover or old.down != pointer.down;
            }
        }
        if (dirty) paint();
        pulp.sleepMs(16);
    }
}
