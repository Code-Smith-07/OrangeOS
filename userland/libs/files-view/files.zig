//! Files and Trash (docs/design/014, M3): browse the real filesystem, and on
//! the /data disk create folders, rename, move to the Trash and put back.
//!
//! A click selects and a double click opens, as on the Mac: folders open
//! here, documents open in their app (Peel chooses it). Space shows Quick
//! Look for the selection. Everything the window shows is laid out from its
//! current size.
const std = @import("std");
const pulp = @import("pulp");
const appkit = @import("appkit");
const ui = appkit.ui;
const K = appkit.K;
const model = @import("model.zig");
const proto = appkit.proto;

var app: appkit.App = undefined;

// ── What is shown ─────────────────────────────────────────────────────────
var path_buf: [256]u8 = undefined;
var path_len: usize = 1;
var entries: [256]pulp.DirEntry = undefined;
var sizes: [256]u64 = undefined;
var all_entries: [256]pulp.DirEntry = undefined;
var all_sizes: [256]u64 = undefined;
var total: usize = 0;
var count: usize = 0;
var listing_capped = false;
var query: ui.TextInput(24) = .{};
var search_active = false;
var selected: ?usize = null;
var page: usize = 0;
var grid_view = true;
var history: [16][256]u8 = undefined;
var history_len: [16]usize = undefined;
var history_count: usize = 0;
/// A problem with the folder itself (shown in place of its items).
var message: []const u8 = "";
/// The result of the last action, shown in the status bar.
var note: []const u8 = "";
var note_bad = false;

// ── Places ────────────────────────────────────────────────────────────────
const DOCUMENTS = "/data/Documents";
const DATA_TRASH = "/data/Trash";
const ORIGINS = "/data/Trash/.origins";
/// The /data disk is attached, so there is somewhere to write.
var has_data = false;
var trash_path: []const u8 = "/Trash";
const Place = struct { name: []const u8, path: []const u8, icon: ui.Icon };
var places: [5]Place = undefined;

fn setupPlaces() void {
    // /data is always a folder; only with a data disk can anything be made
    // in it, so making Documents is the real test.
    pulp.mkdir(DOCUMENTS) catch {};
    has_data = pulp.exists(DOCUMENTS);
    if (has_data) {
        pulp.mkdir(DATA_TRASH) catch {};
        trash_path = DATA_TRASH;
    }
    places = .{
        .{ .name = "Documents", .path = DOCUMENTS, .icon = .sidebar_documents },
        .{ .name = "Orange OS", .path = "/", .icon = .sidebar_home },
        .{ .name = "System", .path = "/etc", .icon = .sidebar_system },
        .{ .name = "Applications", .path = "/bin", .icon = .sidebar_apps },
        .{ .name = "Trash", .path = trash_path, .icon = .sidebar_trash },
    };
}

fn path() []const u8 {
    return path_buf[0..path_len];
}
fn inTrash() bool {
    return std.mem.eql(u8, path(), trash_path);
}
/// Items here can be created, renamed and moved to the Trash.
fn writableHere() bool {
    return has_data and std.mem.startsWith(u8, path(), "/data") and !inTrash();
}
fn fullPath(name: []const u8, out: []u8) ?[]const u8 {
    return std.fmt.bufPrint(out, "{s}{s}{s}", .{ path(), if (path_len == 1) "" else "/", name }) catch null;
}
fn isImage(name: []const u8) bool {
    inline for (.{ ".png", ".bmp", ".ppm" }) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}
fn entryIcon(index: usize) ui.Icon {
    const e = &entries[index];
    const name = e.nameSlice();
    if (e.isDir()) return if (std.mem.eql(u8, name, "Trash")) .trash else .files;
    return if (isImage(name)) .image_file else .document;
}
fn kindText(index: usize) []const u8 {
    const e = &entries[index];
    if (e.isDir()) return "Folder";
    return if (isImage(e.nameSlice())) "Picture" else "Document";
}

// ── Quick Look ────────────────────────────────────────────────────────────
const Look = enum { closed, text, binary, picture, folder, problem };
var look: Look = .closed;
var preview: [65536]u8 = undefined;
var preview_len: usize = 0;
var preview_page: usize = 0;
var preview_lines: usize = 0;
var preview_capped = false;
var look_name: [128]u8 = undefined;
var look_name_len: usize = 0;
var look_size: u64 = 0;
var look_items: usize = 0;
var look_problem: []const u8 = "";
var picture: ?appkit.Picture = null;

fn closeLook() void {
    if (picture) |*p| p.unload();
    picture = null;
    look = .closed;
}

// ── Sheets ────────────────────────────────────────────────────────────────
const SheetKind = enum { none, new_folder, rename, empty_trash };
var sheet: SheetKind = .none;
var input: ui.TextInput(model.MAX_NAME) = .{};
var sheet_error: []const u8 = "";

// ── Layout: everything follows the window size ───────────────────────────
const SIDEBAR_W: i32 = 180;
const BAR: i32 = ui.Metrics.toolbar_h;
const MIN_W: i32 = 660;
const MIN_H: i32 = 380;
const TILE_W: i32 = 118;
const TILE_H: i32 = 137;
/// List rows are the measured macOS table row: 24 points.
const ROW_PITCH: i32 = ui.Metrics.row_h;

fn contentArea() ui.Rect {
    return .{ .x = SIDEBAR_W, .y = BAR + 16, .w = app.width() - SIDEBAR_W, .h = app.height() - 75 - (BAR + 16) };
}
fn columns() usize {
    if (!grid_view) return 1;
    return @intCast(@max(1, @divTrunc(contentArea().w - 16, TILE_W)));
}
fn rowsShown() usize {
    const c = contentArea();
    return @intCast(@max(1, if (grid_view) @divTrunc(c.h + 21, TILE_H) else @divTrunc(c.h - 22, ROW_PITCH)));
}
fn perPage() usize {
    return columns() * rowsShown();
}
fn entryRect(index: usize) ui.Rect {
    const slot = index % perPage();
    const c = contentArea();
    if (!grid_view) return .{ .x = c.x + 12, .y = c.y + 22 + @as(i32, @intCast(slot)) * ROW_PITCH, .w = c.w - 24, .h = ROW_PITCH };
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
    return .{ .x = app.width() - 16 - 64, .y = 12, .w = 64, .h = 28 };
}
fn searchRect() ui.Rect {
    const w = @min(@as(i32, 180), @max(110, app.width() - SIDEBAR_W - 440));
    return .{ .x = viewControl().x - 10 - w, .y = 15, .w = w, .h = ui.Metrics.search_h };
}
/// New Folder (or Put Back), Move to Trash (or Empty), Quick Look.
fn toolButton(i: usize) ui.Rect {
    return .{ .x = searchRect().x - 12 - @as(i32, @intCast(3 - i)) * 32, .y = 12, .w = 28, .h = 28 };
}
fn sidebarRow(i: usize) ui.Rect {
    return .{ .x = 10, .y = BAR + 24 + @as(i32, @intCast(i)) * 30, .w = SIDEBAR_W - 20, .h = 28 };
}
fn lookBox() ui.Rect {
    const c = contentArea();
    return .{ .x = c.x + 18, .y = BAR + 52, .w = c.w - 36, .h = app.height() - (BAR + 52) - 66 };
}
fn lookLines() usize {
    return @intCast(@max(1, @divTrunc(lookBox().h - 16, 18)));
}
fn lookColumns() usize {
    return @intCast(std.math.clamp(@divTrunc(lookBox().w - 28, 8), 20, @as(i32, model.MAX_COLUMNS)));
}
fn pageButton(i: usize) ui.Rect {
    return .{ .x = app.width() - 106 + @as(i32, @intCast(i)) * 50, .y = app.height() - 45, .w = 42, .h = 27 };
}
fn sheetLayout() ui.Sheet {
    return ui.Sheet.layout(app.width(), app.height(), 2, sheet != .empty_trash);
}

// ── Reading folders ───────────────────────────────────────────────────────

fn filter() void {
    count = 0;
    for (all_entries[0..total], 0..) |e, i| {
        if (!model.matches(e.nameSlice(), query.text())) continue;
        entries[count] = e;
        sizes[count] = all_sizes[i];
        count += 1;
    }
    page = 0;
    selected = null;
    if (pulp.desktop_profile) pulp.print("files: filter '{s}': {d} matches\n", .{ query.text(), count });
}

fn load() void {
    closeLook();
    page = 0;
    query.clear();
    search_active = false;
    selected = null;
    message = "";
    count = 0;
    while (count < entries.len) {
        const n = pulp.readdirPage(path(), entries[count..], count) catch {
            message = if (!has_data and std.mem.startsWith(u8, path(), "/data")) "No data disk is attached, so there is no Documents folder." else "This folder could not be read.";
            count = 0;
            total = 0;
            pulp.print("files: cannot list {s}\n", .{path()});
            return;
        };
        count += n;
        if (n < 32) break;
    }
    var extra: [1]pulp.DirEntry = undefined;
    listing_capped = count == entries.len and (pulp.readdirPage(path(), &extra, count) catch 1) != 0;
    var visible: usize = 0;
    for (0..count) |i| {
        // Names starting with a dot are hidden (the Trash keeps its notes there).
        const name = entries[i].nameSlice();
        if (name.len == 0 or name[0] == '.') continue;
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
    for (0..count) |i| {
        var buf: [400]u8 = undefined;
        sizes[i] = 0;
        if (entries[i].isDir()) continue;
        const full = fullPath(entries[i].nameSlice(), &buf) orelse continue;
        if (pulp.stat(full)) |st| sizes[i] = st.size else |_| {}
    }
    total = count;
    @memcpy(all_entries[0..total], entries[0..count]);
    @memcpy(all_sizes[0..total], sizes[0..count]);
    listing_signature = signature();
    pulp.print("files: listed {s}: {d} entries\n", .{ path(), count });
}

/// A fingerprint of the folder as it is on disk now: names and kinds.
/// When it differs from the one taken at the last listing, another program
/// (the editor saving, a shell command) changed the folder.
var listing_signature: u64 = 0;
fn signature() u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var batch: [32]pulp.DirEntry = undefined;
    var skip: usize = 0;
    while (skip < 256) {
        const n = pulp.readdirPage(path(), &batch, skip) catch return 0;
        for (batch[0..n]) |*e| {
            // Order on disk can differ between readings; add, do not chain.
            var one: u64 = @as(u64, 0xcbf29ce484222325) ^ e.type;
            for (e.nameSlice()) |c| one = (one ^ c) *% 0x100000001b3;
            hash +%= one;
        }
        skip += n;
        if (n < batch.len) break;
    }
    return hash;
}

/// Show changes other programs made to this folder, keeping the selection.
fn refreshIfChanged() bool {
    if (sheet != .none or look != .closed or search_active or query.len > 0 or message.len > 0) return false;
    if (signature() == listing_signature) return false;
    var keep: [128]u8 = undefined;
    var keep_len: usize = 0;
    if (selected) |i| {
        keep_len = entries[i].name_len;
        @memcpy(keep[0..keep_len], entries[i].nameSlice());
    }
    const old_note = note;
    reloadSelecting(keep[0..keep_len]);
    note = old_note;
    return true;
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
    std.mem.copyForwards(u8, path_buf[0..next.len], next);
    path_len = next.len;
    note = "";
    load();
}

/// Reload this folder and select `name` if it is still here.
fn reloadSelecting(name: []const u8) void {
    load();
    for (0..count) |i| if (std.mem.eql(u8, entries[i].nameSlice(), name)) {
        selected = i;
        page = i / perPage();
        break;
    };
}

fn say(text: []const u8, bad: bool) void {
    note = text;
    note_bad = bad;
}

// ── Opening and Quick Look ────────────────────────────────────────────────

fn openEntry(index: usize) void {
    if (index >= count) return;
    const e = &entries[index];
    var buf: [400]u8 = undefined;
    const full = fullPath(e.nameSlice(), &buf) orelse {
        say("That path is too long.", true);
        return;
    };
    if (e.isDir()) {
        navigate(full, true);
        return;
    }
    // A document: Peel starts the app that handles it.
    pulp.print("files: open {s}\n", .{full});
    app.win.openDocument(full);
}

fn quickLook(index: usize) void {
    if (index >= count) return;
    closeLook();
    const e = &entries[index];
    var buf: [400]u8 = undefined;
    const full = fullPath(e.nameSlice(), &buf) orelse return;
    look_name_len = e.name_len;
    @memcpy(look_name[0..look_name_len], e.nameSlice());
    look_size = sizes[index];
    preview_page = 0;
    search_active = false;
    if (e.isDir()) {
        var inside: [64]pulp.DirEntry = undefined;
        const n = pulp.readdirPage(full, &inside, 0) catch 0;
        look_items = 0;
        for (inside[0..n]) |*x| {
            const name = x.nameSlice();
            if (name.len > 0 and name[0] != '.') look_items += 1;
        }
        look = .folder;
        pulp.print("files: quick look folder {s}, {d} items\n", .{ full, look_items });
        return;
    }
    if (isImage(e.nameSlice())) {
        if (appkit.Picture.load(full, 0xFFFFFF)) |p| {
            picture = p;
            look = .picture;
            pulp.print("files: quick look picture {s}, {d}x{d}\n", .{ full, p.img.width, p.img.height });
        } else |err| {
            look_problem = appkit.Picture.problem(err);
            look = .problem;
            pulp.print("files: quick look picture {s} failed\n", .{full});
        }
        return;
    }
    const got = appkit.readFile(full, &preview, &preview_capped) orelse {
        look_problem = "This file could not be read.";
        look = .problem;
        return;
    };
    preview_len = got.len;
    look = .text;
    for (preview[0..preview_len]) |ch| {
        if ((ch < 32 and ch != '\n' and ch != '\r' and ch != '\t') or ch > 126) {
            look = .binary;
            break;
        }
    }
    preview_lines = model.lineCountWidth(preview[0..preview_len], lookColumns());
    pulp.print("files: preview {s}, {d} bytes\n", .{ full, preview_len });
}

// ── Changing things on /data ──────────────────────────────────────────────

/// A name not yet used in `dir`: `name` itself, or with a number added.
fn freeName(dir: []const u8, name: []const u8, out: []u8) ?[]const u8 {
    var probe: [400]u8 = undefined;
    var n: usize = 1;
    while (n < 100) : (n += 1) {
        const candidate = if (n == 1) (if (name.len <= out.len) blk: {
            @memcpy(out[0..name.len], name);
            break :blk out[0..name.len];
        } else return null) else model.numbered(name, n, out) orelse return null;
        const full = std.fmt.bufPrint(&probe, "{s}/{s}", .{ dir, candidate }) catch return null;
        if (!pulp.exists(full)) return candidate;
    }
    return null;
}

fn readOrigins(buf: []u8) []const u8 {
    return appkit.readFile(ORIGINS, buf, null) orelse "";
}

fn moveToTrash(index: usize) void {
    if (index >= count) return;
    if (!writableHere()) {
        say("Only items on the data disk can be moved to the Trash.", true);
        return;
    }
    const name = entries[index].nameSlice();
    var from_buf: [400]u8 = undefined;
    const from = fullPath(name, &from_buf) orelse return;
    var name_buf: [140]u8 = undefined;
    const trash_name = freeName(DATA_TRASH, name, &name_buf) orelse {
        say("The Trash could not take this item.", true);
        return;
    };
    var to_buf: [400]u8 = undefined;
    const to = std.fmt.bufPrint(&to_buf, "{s}/{s}", .{ DATA_TRASH, trash_name }) catch return;
    pulp.rename(from, to) catch {
        say("This item could not be moved to the Trash.", true);
        return;
    };
    // Remember where it was, for Put Back.
    var origins_buf: [8192]u8 = undefined;
    const old = readOrigins(origins_buf[0 .. origins_buf.len - 600]);
    const line = std.fmt.bufPrint(origins_buf[old.len..], "{s}\t{s}\n", .{ trash_name, from }) catch "";
    _ = appkit.writeFileAtomic(ORIGINS, origins_buf[0 .. old.len + line.len]);
    pulp.print("files: moved {s} to the Trash\n", .{from});
    var body: [120]u8 = undefined;
    app.win.notify("Moved to Trash", std.fmt.bufPrint(&body, "{s}", .{ui.fitting(name, 300)}) catch name[0..@min(name.len, 100)]);
    load();
    say("Moved to the Trash.", false);
}

fn putBack(index: usize) void {
    if (index >= count or !inTrash() or !has_data) return;
    const name = entries[index].nameSlice();
    var from_buf: [400]u8 = undefined;
    const from = fullPath(name, &from_buf) orelse return;
    var origins_buf: [8192]u8 = undefined;
    const origins = readOrigins(&origins_buf);
    // Back where it was if that folder is still there; else to Documents.
    var dir: []const u8 = DOCUMENTS;
    var wanted: []const u8 = name;
    if (model.originOf(origins, name)) |origin| {
        const parent = model.parentOf(origin);
        if (std.mem.startsWith(u8, parent, "/data") and pulp.exists(parent)) {
            dir = parent;
            wanted = appkit.basename(origin);
        }
    }
    var name_buf: [140]u8 = undefined;
    const final = freeName(dir, wanted, &name_buf) orelse {
        say("This item could not be put back.", true);
        return;
    };
    var to_buf: [400]u8 = undefined;
    const to = std.fmt.bufPrint(&to_buf, "{s}/{s}", .{ dir, final }) catch return;
    pulp.rename(from, to) catch {
        say("This item could not be put back.", true);
        return;
    };
    var kept: [8192]u8 = undefined;
    _ = appkit.writeFileAtomic(ORIGINS, model.withoutOrigin(origins, name, &kept));
    pulp.print("files: put back {s}\n", .{to});
    load();
    say("Put back where it was.", false);
}

/// Delete a file, or a folder and everything in it. False if any part
/// could not be deleted (what was deleted stays deleted).
fn removeTree(buf: *[400]u8, len: usize, depth: usize) bool {
    const st = pulp.stat(buf[0..len]) catch return true;
    if (!st.isDir()) {
        pulp.unlink(buf[0..len]) catch return false;
        return true;
    }
    if (depth > 24) return false;
    var batch: [16]pulp.DirEntry = undefined;
    while (true) {
        const n = pulp.readdirPage(buf[0..len], &batch, 0) catch return false;
        var removed = false;
        for (batch[0..n]) |*e| {
            const name = e.nameSlice();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (len + 1 + name.len > buf.len) return false;
            buf[len] = '/';
            @memcpy(buf[len + 1 ..][0..name.len], name);
            if (!removeTree(buf, len + 1 + name.len, depth + 1)) return false;
            removed = true;
        }
        if (!removed) break;
    }
    pulp.rmdir(buf[0..len]) catch return false;
    return true;
}

fn emptyTrash() void {
    if (!has_data) return;
    var buf: [400]u8 = undefined;
    var ok = true;
    var removed: usize = 0;
    var batch: [16]pulp.DirEntry = undefined;
    // Only what is inside the Trash folder; the folder itself stays.
    while (ok) {
        const n = pulp.readdirPage(DATA_TRASH, &batch, 0) catch break;
        var any = false;
        for (batch[0..n]) |*e| {
            const name = e.nameSlice();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ DATA_TRASH, name }) catch continue;
            if (!removeTree(&buf, full.len, 0)) {
                ok = false;
                break;
            }
            any = true;
            if (name[0] != '.') removed += 1;
        }
        if (!any) break;
    }
    pulp.print("files: emptied the Trash, {d} items\n", .{removed});
    load();
    say(if (ok) "The Trash is empty." else "Some items could not be deleted.", !ok);
}

fn openSheet(kind: SheetKind) void {
    sheet_error = "";
    switch (kind) {
        .new_folder => {
            if (!writableHere()) {
                say(if (has_data) "Folders can be made in Documents, on the data disk." else "No data disk is attached, so nothing can be saved.", true);
                return;
            }
            var buf: [model.MAX_NAME]u8 = undefined;
            input.set(freeName(path(), "untitled folder", &buf) orelse "untitled folder");
        },
        .rename => {
            const i = selected orelse {
                say("Select an item to rename first.", true);
                return;
            };
            if (!writableHere()) {
                say("Only items on the data disk can be renamed.", true);
                return;
            }
            input.set(entries[i].nameSlice());
        },
        .empty_trash => if (!has_data or !inTrash() or total == 0) return,
        .none => {},
    }
    closeLook();
    sheet = kind;
}

fn confirmSheet() void {
    switch (sheet) {
        .new_folder, .rename => {
            const name = input.text();
            const problem = model.checkName(name);
            if (problem != .ok) {
                sheet_error = model.problemText(problem);
                return;
            }
            var buf: [400]u8 = undefined;
            const target = fullPath(name, &buf) orelse {
                sheet_error = "That path is too long.";
                return;
            };
            var keep: [model.MAX_NAME]u8 = undefined;
            @memcpy(keep[0..name.len], name);
            if (sheet == .new_folder) {
                if (pulp.exists(target)) {
                    sheet_error = "That name is already used here.";
                    return;
                }
                // mkdir treats "already there" as success, hence the check.
                pulp.mkdir(target) catch {
                    sheet_error = "The folder could not be made.";
                    return;
                };
                pulp.print("files: new folder {s}\n", .{target});
            } else {
                const i = selected orelse return;
                const old = entries[i].nameSlice();
                if (std.mem.eql(u8, old, name)) {
                    sheet = .none;
                    return;
                }
                if (pulp.exists(target)) {
                    sheet_error = "That name is already used here.";
                    return;
                }
                var from_buf: [400]u8 = undefined;
                const from = fullPath(old, &from_buf) orelse return;
                pulp.rename(from, target) catch {
                    sheet_error = "The item could not be renamed.";
                    return;
                };
                pulp.print("files: renamed {s} to {s}\n", .{ from, target });
            }
            sheet = .none;
            reloadSelecting(keep[0..name.len]);
        },
        .empty_trash => {
            sheet = .none;
            emptyTrash();
        },
        .none => {},
    }
}

// ── Click targets ─────────────────────────────────────────────────────────
// 1 back, 2 up, 10.. places, 20/21 pages, 30/31 view, 32 search, 40..42
// toolbar actions, 50/51 sheet buttons, 100+ items.

const MAX_TARGETS = 14 + 96;
fn targets(out: *[MAX_TARGETS]ui.Button) []const ui.Button {
    if (sheet != .none) {
        const layout = sheetLayout();
        out[0] = .{ .id = 50, .rect = layout.buttons[0] };
        out[1] = .{ .id = 51, .rect = layout.buttons[1] };
        return out[0..2];
    }
    out[0] = .{ .id = 1, .rect = backButton() };
    out[1] = .{ .id = 2, .rect = upButton() };
    for (0..places.len) |i| out[2 + i] = .{ .id = @intCast(10 + i), .rect = sidebarRow(i) };
    out[7] = .{ .id = 20, .rect = pageButton(0) };
    out[8] = .{ .id = 21, .rect = pageButton(1) };
    out[9] = .{ .id = 30, .rect = ui.segment(viewControl(), 2, 0) };
    out[10] = .{ .id = 31, .rect = ui.segment(viewControl(), 2, 1) };
    out[11] = .{ .id = 32, .rect = searchRect() };
    var n: usize = 12;
    for (0..3) |i| {
        out[n] = .{ .id = @intCast(40 + i), .rect = toolButton(i) };
        n += 1;
    }
    if (look == .closed) {
        const per = perPage();
        for (page * per..@min(count, (page + 1) * per, page * per + MAX_TARGETS - 15)) |i| {
            out[n] = .{ .id = @intCast(100 + i), .rect = entryRect(i) };
            n += 1;
        }
    }
    return out[0..n];
}

/// Do what a button, a menu item or a key asks; true when the window
/// must be drawn again.
fn act(id: u32) bool {
    switch (id) {
        1 => {
            if (look != .closed) {
                closeLook();
            } else if (history_count > 0) {
                history_count -= 1;
                navigate(history[history_count][0..history_len[history_count]], false);
            } else return false;
        },
        2 => {
            if (look != .closed) {
                closeLook();
            } else if (path_len > 1) {
                var parent: [256]u8 = undefined;
                @memcpy(parent[0..path_len], path());
                navigate(model.parentOf(parent[0..path_len]), true);
            } else return false;
        },
        10...14 => {
            // Choosing the place already shown reads it again.
            navigate(places[id - 10].path, true);
        },
        20, 21 => {
            if (look == .text) {
                if (id == 20 and preview_page > 0) {
                    preview_page -= 1;
                } else if (id == 21 and (preview_page + 1) * lookLines() < preview_lines) {
                    preview_page += 1;
                } else return false;
                pulp.print("files: preview page {d}\n", .{preview_page + 1});
            } else if (look == .closed and id == 20 and page > 0) {
                page -= 1;
                selected = null;
            } else if (look == .closed and id == 21 and (page + 1) * perPage() < count) {
                page += 1;
                selected = null;
            } else return false;
        },
        30, 31 => {
            const next = id == 30;
            if (next == grid_view) return false;
            const first = page * perPage();
            grid_view = next;
            page = first / perPage();
            pulp.print("files: view {s}\n", .{if (grid_view) "grid" else "list"});
        },
        32 => {
            if (look != .closed or search_active) return false;
            search_active = true;
        },
        // New Folder, or Put Back in the Trash.
        40 => if (inTrash()) {
            if (selected) |i| putBack(i) else say("Select an item to put back first.", true);
        } else openSheet(.new_folder),
        // Move to Trash, or Empty Trash in the Trash.
        41 => if (inTrash()) openSheet(.empty_trash) else if (selected) |i| moveToTrash(i) else say("Select an item first.", true),
        42 => if (look != .closed) closeLook() else if (selected) |i| quickLook(i) else say("Select an item first.", true),
        44 => if (selected) |i| openEntry(i) else return false,
        45 => openSheet(.rename),
        50 => sheet = .none,
        51 => confirmSheet(),
        else => return false,
    }
    return true;
}

fn key(k: appkit.Key) bool {
    if (!k.down) return false;
    if (sheet != .none) {
        if (k.code == K.esc) return act(50);
        if (k.code == K.enter) return act(51);
        if (sheet == .empty_trash) return false;
        if (k.ch != 0) {
            sheet_error = "";
            return input.insert(k.ch);
        }
        if (input.editKey(k.code)) {
            sheet_error = "";
            return true;
        }
        return false;
    }
    if (look != .closed) {
        switch (k.code) {
            K.space, K.esc => closeLook(),
            K.page_up, K.up => return act(20),
            K.page_down, K.down => return act(21),
            K.backspace => return act(1),
            else => return false,
        }
        return true;
    }
    if (search_active) {
        if (k.code == K.esc) {
            query.clear();
            search_active = false;
            filter();
            return true;
        }
        if (k.code == K.enter or k.code == K.down) {
            search_active = false;
            selected = if (count > 0) 0 else null;
            return true;
        }
        if (k.code == K.backspace) {
            if (!query.backspace()) return false;
        } else if (k.ch == 0 or !query.insert(k.ch)) return false;
        filter();
        return true;
    }
    if ((k.ctrl and k.code == 0x21) or (k.ch == '/' and !k.ctrl)) return act(32);
    if (k.ctrl and k.shift and k.code == 0x31) return act(40); // Ctrl+Shift+N
    if (k.code == K.f2) return act(45);
    if (k.code == K.delete or (k.ctrl and k.code == K.backspace)) return act(41);
    if (k.code == K.space) return act(42);
    if (k.code == K.esc and query.len > 0) {
        query.clear();
        filter();
        return true;
    }
    if (k.code == K.backspace or k.code == K.esc) return act(1);
    if (k.code == K.page_up) return act(20);
    if (k.code == K.page_down) return act(21);
    if (k.code == K.enter) return act(44);
    if (count == 0) return false;
    var next = selected orelse page * perPage();
    const step: usize = if (grid_view and (k.code == K.up or k.code == K.down)) columns() else 1;
    switch (k.code) {
        K.home => next = 0,
        K.end => next = count - 1,
        K.up, K.left => if (selected != null) {
            next -|= step;
        },
        K.down, K.right => if (selected != null) {
            next = @min(count - 1, next + step);
        },
        else => return false,
    }
    if (selected == next) return false;
    selected = next;
    page = next / perPage();
    if (pulp.desktop_profile) pulp.print("files: selected {s}\n", .{entries[next].nameSlice()});
    return true;
}

// ── Drawing ───────────────────────────────────────────────────────────────

fn centeredLabel(s: *ui.Surface, text: []const u8, y: i32, scale: i32, color: u32) void {
    const c = contentArea();
    const shown = ui.fitting(text, c.w - 24);
    ui.label(s, shown, c.x + @divTrunc(c.w - ui.textWidth(shown, scale), 2), y, scale, color);
}

fn paintLook(s: *ui.Surface, area: ui.Rect) void {
    const box = lookBox();
    const H = app.height();
    const c = contentArea();
    ui.label(s, ui.fitting(look_name[0..look_name_len], box.w - 12), box.x + 6, BAR + 26, 1, 0x253247);
    s.rounded(box, 10, 0xF4F7FB, 255);
    var status_buf: [120]u8 = undefined;
    var size_buf: [24]u8 = undefined;
    var status: []const u8 = "";
    switch (look) {
        .text => {
            const lines = lookLines();
            const cols = lookColumns();
            s.setClip(ui.Rect.intersect(area, .{ .x = box.x + 14, .y = box.y + 8, .w = box.w - 28, .h = box.h - 12 }));
            var pos: usize = 0;
            var row: usize = 0;
            while (pos < preview_len and row < (preview_page + 1) * lines) : (row += 1) {
                const span = model.lineAtWidth(preview[0..preview_len], pos, cols);
                pos = span.next;
                if (row < preview_page * lines) continue;
                var line: [model.MAX_COLUMNS]u8 = undefined;
                var used: usize = 0;
                for (preview[span.start..span.end]) |ch| {
                    if (ch == '\r') continue;
                    line[used] = if (ch == '\t') ' ' else ch;
                    used += 1;
                }
                ui.monoLabel(s, line[0..used], box.x + 14, box.y + 16 + @as(i32, @intCast(row - preview_page * lines)) * 18, 0x556378);
            }
            s.setClip(area);
            status = std.fmt.bufPrint(&status_buf, "{d} bytes{s} / Page {d} of {d}", .{ preview_len, if (preview_capped) " (64 KiB limit)" else "", preview_page + 1, @max(1, (preview_lines + lines - 1) / lines) }) catch "";
            if (preview_page > 0) ui.icon(s, .chevron_left, pageButton(0).x + 11, H - 42, 20);
            if ((preview_page + 1) * lines < preview_lines) ui.icon(s, .chevron_right, pageButton(1).x + 11, H - 42, 20);
        },
        .binary => {
            ui.icon(s, .document, box.x + @divTrunc(box.w - 64, 2), box.y + 28, 64);
            const t = "No text preview for this file.";
            ui.label(s, t, box.x + @divTrunc(box.w - ui.textWidth(t, 1), 2), box.y + 112, 1, 0x556378);
            status = "Binary preview unavailable";
        },
        .picture => if (picture) |*p| {
            const size = appkit.image.fit(p.img.width, p.img.height, box.w - 24, box.h - 24, 100);
            const dest = ui.Rect{ .x = box.x + @divTrunc(box.w - size[0], 2), .y = box.y + @divTrunc(box.h - size[1], 2), .w = size[0], .h = size[1] };
            appkit.drawImage(s, &p.img, dest);
            status = std.fmt.bufPrint(&status_buf, "{d} x {d} pixels / {s}", .{ p.img.width, p.img.height, model.sizeText(look_size, &size_buf) }) catch "";
        },
        .folder => {
            ui.icon(s, .files, box.x + @divTrunc(box.w - 96, 2), box.y + @max(12, @divTrunc(box.h - 150, 2)), 96);
            var buf: [48]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d} {s}", .{ look_items, if (look_items == 1) "item" else "items" }) catch "";
            ui.label(s, t, box.x + @divTrunc(box.w - ui.textWidth(t, 1), 2), box.y + @max(12, @divTrunc(box.h - 150, 2)) + 116, 1, 0x556378);
            status = "Folder";
        },
        .problem => {
            ui.label(s, ui.fitting(look_problem, box.w - 48), box.x + 24, box.y + 42, 1, 0xB05251);
            status = "Quick Look";
        },
        .closed => {},
    }
    ui.label(s, ui.fitting(status, pageButton(0).x - 16 - (c.x + 10)), c.x + 10, H - 36, 1, 0x778397);
}

fn paintItems(s: *ui.Surface, area: ui.Rect) void {
    const W = app.width();
    const c = contentArea();
    const pointer = app.pointer;
    if (!grid_view) {
        ui.label(s, "Name", c.x + 44, c.y + 4, 1, 0x7A7D84);
        ui.label(s, "Size", W - 186, c.y + 4, 1, 0x7A7D84);
        ui.label(s, "Kind", W - 100, c.y + 4, 1, 0x7A7D84);
        s.fill(.{ .x = c.x + 12, .y = c.y + 20, .w = c.w - 24, .h = 1 }, 0xE6E9EE);
    }
    const per = perPage();
    for (page * per..@min(count, (page + 1) * per)) |i| {
        const r = entryRect(i);
        const name = entries[i].nameSlice();
        const chosen = selected == i;
        const hot = pointer.hover == 100 + i;
        if (grid_view) {
            if (chosen or hot) s.rounded(r, 11, if (chosen) 0xD6E6FC else 0xEDF4FD, 255);
            ui.icon(s, entryIcon(i), r.x + 24, r.y + 8, 64);
            const shown = ui.fitting(name, 102);
            // The selected name sits on an accent pill, as in the Finder.
            if (chosen) s.rounded(.{ .x = r.x + @divTrunc(r.w - ui.textWidth(shown, 1), 2) - 5, .y = r.y + 80, .w = ui.textWidth(shown, 1) + 10, .h = 20 }, 5, ui.Tone.accent, 255);
            s.setClip(ui.Rect.intersect(area, .{ .x = r.x + 2, .y = r.y + 78, .w = 108, .h = 24 }));
            ui.label(s, shown, r.x + @divTrunc(r.w - ui.textWidth(shown, 1), 2), r.y + 87, 1, if (chosen) 0xFFFFFF else 0x253247);
            s.setClip(area);
        } else {
            const ink: u32 = if (chosen) 0xFFFFFF else 0x253247;
            const dim: u32 = if (chosen) 0xE6EFFD else 0x8994A5;
            if (chosen) s.rounded(r, 5, ui.Tone.accent, 255) else if (hot) s.rounded(r, 5, 0xEDF4FD, 255) else if (i % 2 == 1) s.rounded(r, 5, 0xF6F8FB, 255);
            ui.icon(s, entryIcon(i), r.x + 8, r.y + 3, 18);
            s.setClip(ui.Rect.intersect(area, .{ .x = r.x + 32, .y = r.y, .w = r.w - 32 - 190, .h = r.h }));
            ui.label(s, name, r.x + 32, r.y + 8, 1, ink);
            s.setClip(area);
            var size_buf: [24]u8 = undefined;
            ui.label(s, if (entries[i].isDir()) "--" else model.sizeText(sizes[i], &size_buf), W - 186, r.y + 8, 1, dim);
            ui.label(s, kindText(i), W - 100, r.y + 8, 1, dim);
        }
    }
}

fn paint(area: ui.Rect) void {
    var s = app.surface();
    s.setClip(area);
    const W = app.width();
    const H = app.height();
    const T = ui.Tone;
    const pointer = app.pointer;
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, 0xFFFFFF);
    // Sidebar, full height: the window buttons sit on its top.
    s.fill(.{ .x = 0, .y = 0, .w = SIDEBAR_W, .h = H }, T.sidebar);
    s.fill(.{ .x = SIDEBAR_W - 1, .y = 0, .w = 1, .h = H }, T.hairline);
    s.fill(.{ .x = SIDEBAR_W, .y = 0, .w = W - SIDEBAR_W, .h = BAR }, T.toolbar);
    s.fill(.{ .x = SIDEBAR_W, .y = BAR - 1, .w = W - SIDEBAR_W, .h = 1 }, T.hairline);
    for ([_]ui.Rect{ backButton(), upButton() }, 0..) |r, i| {
        var st = ui.ControlState.of(pointer, @intCast(i + 1));
        st.enabled = look != .closed or (if (i == 0) history_count > 0 else path_len > 1);
        ui.toolbarButton(&s, r, if (i == 0) .chevron_left else .chevron_up, st);
    }
    // Toolbar actions: what they do depends on the folder.
    const trash = inTrash();
    const icons = [3]ui.Icon{ if (trash) .sym_restore else .sym_folder_plus, .sidebar_trash, .sym_eye };
    const enabled = [3]bool{
        if (trash) selected != null and has_data else writableHere(),
        if (trash) total > 0 and has_data else selected != null and writableHere(),
        selected != null or look != .closed,
    };
    for (0..3) |i| {
        var st = ui.ControlState.of(pointer, @intCast(40 + i));
        st.enabled = enabled[i];
        st.selected = i == 2 and look != .closed;
        ui.toolbarButton(&s, toolButton(i), icons[i], st);
    }
    // The folder's name, between the buttons and the actions.
    var basename: []const u8 = if (path_len == 1) "Orange OS" else appkit.basename(path());
    for (places) |place| if (std.mem.eql(u8, place.path, path())) {
        basename = place.name;
    };
    const title_x = upButton().right() + 14;
    ui.label(&s, ui.fitting(basename, toolButton(0).x - 10 - title_x), title_x, 22, 1, T.text);
    ui.searchField(&s, searchRect(), query.text(), if (search_active) "Type to filter..." else "Search", search_active);
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
    for (places, 0..) |place, i| {
        const r = sidebarRow(i);
        const active = std.mem.eql(u8, path(), place.path);
        if (active or pointer.hover == 10 + i) s.rounded(r, 6, if (pointer.pressed == 10 + i) 0xCAD8E8 else if (active) 0xD7E0EB else 0xE3E4E8, 255);
        ui.icon(&s, place.icon, r.x + 8, r.y + 5, 18);
        ui.label(&s, ui.fitting(place.name, r.w - 40), r.x + 33, r.y + 10, 1, 0x3D4046);
    }
    s.fill(.{ .x = 20, .y = H - 71, .w = SIDEBAR_W - 40, .h = 1 }, 0xDFE6EF);
    // Real space on the data disk, or why nothing can be saved.
    var space_buf: [48]u8 = undefined;
    var size_buf: [24]u8 = undefined;
    var space: []const u8 = "No data disk attached";
    if (has_data) if (pulp.statfs("/data")) |fs| {
        space = std.fmt.bufPrint(&space_buf, "{s} available", .{model.sizeText(fs.free_bytes, &size_buf)}) catch "";
    } else |_| {};
    ui.label(&s, "Data disk", 20, H - 57, 1, 0x778397);
    ui.label(&s, ui.fitting(space, SIDEBAR_W - 36), 20, H - 34, 1, 0x778397);

    const c = contentArea();
    if (look != .closed) {
        paintLook(&s, area);
    } else if (message.len > 0) {
        centeredLabel(&s, message, BAR + 91, 1, 0xB05251);
    } else if (count == 0) {
        ui.icon(&s, if (trash) .trash else .files, c.x + @divTrunc(c.w - 86, 2), BAR + 79, 86);
        centeredLabel(&s, if (query.len > 0) "No matches" else if (trash) "Trash is empty" else "An empty folder", BAR + 186, 2, 0x253247);
        centeredLabel(&s, if (query.len > 0) "Try another name. Esc clears the search." else if (trash) "Items you move to the Trash appear here." else if (writableHere()) "Use New Folder, or save a document here." else "There are no items to show here.", BAR + 232, 1, 0x778397);
    } else paintItems(&s, area);

    if (look == .closed) {
        var b: [96]u8 = undefined;
        s.setClip(ui.Rect.intersect(area, .{ .x = c.x + 10, .y = H - 80, .w = c.w - 20, .h = 24 }));
        ui.label(&s, path(), c.x + 10, H - 67, 1, 0x8A8D93);
        s.setClip(area);
        const status = if (note.len > 0) note else std.fmt.bufPrint(&b, "{d}/{d} items{s} / Page {d}", .{ count, total, if (listing_capped) " (256 limit)" else "", page + 1 }) catch "";
        s.fill(.{ .x = c.x + 2, .y = H - 51, .w = c.w - 4, .h = 1 }, 0xEDF1F6);
        ui.label(&s, ui.fitting(status, pageButton(0).x - 16 - (c.x + 10)), c.x + 10, H - 36, 1, if (note.len > 0 and note_bad) 0xB05251 else 0x778397);
        for (0..2) |i| {
            const id = 20 + i;
            if (pointer.hover == id) s.rounded(pageButton(i), 7, if (pointer.pressed == id) 0xDFEBFC else 0xEDF4FD, 255);
        }
        if (page > 0) ui.icon(&s, .chevron_left, pageButton(0).x + 11, H - 42, 20);
        if ((page + 1) * perPage() < count) ui.icon(&s, .chevron_right, pageButton(1).x + 11, H - 42, 20);
    } else {
        s.fill(.{ .x = c.x + 2, .y = H - 51, .w = c.w - 4, .h = 1 }, 0xEDF1F6);
    }

    if (sheet != .none) {
        const layout = sheetLayout();
        var text_buf: [96]u8 = undefined;
        const title: []const u8 = switch (sheet) {
            .new_folder => "New Folder",
            .rename => "Rename",
            else => "Empty the Trash?",
        };
        const text: []const u8 = if (sheet_error.len > 0) sheet_error else switch (sheet) {
            .new_folder => "Name of the new folder:",
            .rename => "New name:",
            else => std.fmt.bufPrint(&text_buf, "{d} {s} will be deleted. This cannot be undone.", .{ total, if (total == 1) "item" else "items" }) catch "",
        };
        const labels: [2][]const u8 = .{ "Cancel", switch (sheet) {
            .new_folder => "Create",
            .rename => "Rename",
            else => "Empty Trash",
        } };
        layout.paint(&s, W, H, title, text, &labels, pointer, 50);
        if (sheet != .empty_trash) ui.textField(&s, layout.field, input.text(), input.caret, true, false, "");
    }
    app.present(area);
    if (pulp.desktop_profile) pulp.puts("files: painted\n");
}

const MENU =
    "MFile\n" ++
    "I40 New Folder\tCtrl+Shift+N\n" ++
    "I44 Open\tReturn\n" ++
    "I42 Quick Look\tSpace\n" ++
    "-\n" ++
    "I45 Rename\tF2\n" ++
    "I41 Move to Trash\tDelete\n" ++
    "MView\n" ++
    "I30 as Icons\n" ++
    "I31 as List\n" ++
    "MGo\n" ++
    "I1 Back\n" ++
    "I2 Enclosing Folder\n" ++
    "-\n" ++
    "I10 Documents\n" ++
    "I11 Orange OS\n" ++
    "I13 Applications\n" ++
    "I14 Trash\n";

fn whole() ui.Rect {
    return .{ .x = 0, .y = 0, .w = app.width(), .h = app.height() };
}

pub fn run(start_in_trash: bool) noreturn {
    app = appkit.App.open(.{
        .title = if (start_in_trash) "Trash" else "Files",
        .app = if (start_in_trash) proto.App.trash else proto.App.files,
        .width = 680,
        .height = 450,
        .x = 260,
        .y = 170,
        .min_w = MIN_W,
        .min_h = MIN_H,
        .bar_height = BAR,
        .menu = MENU,
    });
    setupPlaces();
    // Documents is home when there is a data disk; otherwise the computer.
    navigate(if (start_in_trash) trash_path else if (has_data) DOCUMENTS else "/", false);
    paint(whole());
    var last_check = pulp.uptimeMs();
    while (true) {
        const previous = app.pointer;
        var changed = false;
        if (pulp.uptimeMs() -| last_check >= 1500) {
            last_check = pulp.uptimeMs();
            changed = refreshIfChanged();
        }
        while (app.next()) |event| switch (event) {
            .close => app.quit(),
            .resized => {
                if (selected) |sel| page = sel / perPage() else page = @min(page, if (count == 0) 0 else (count - 1) / perPage());
                if (look == .text) {
                    preview_lines = model.lineCountWidth(preview[0..preview_len], lookColumns());
                    preview_page = @min(preview_page, if (preview_lines == 0) 0 else (preview_lines - 1) / lookLines());
                }
                paint(whole());
                app.presentAll();
                if (pulp.desktop_profile) pulp.print("files: resized to {d}x{d}, {d} per page\n", .{ app.width(), app.height(), perPage() });
            },
            .menu => |id| changed = act(id) or changed,
            .open_file => |p| {
                // Peel asks this window to show a folder (Spotlight, Open).
                if (pulp.stat(p)) |st| {
                    if (st.isDir()) {
                        navigate(p, true);
                        changed = true;
                    }
                } else |_| {}
            },
            .key => |k| changed = key(k) or changed,
            .mouse => |m| {
                var buttons: [MAX_TARGETS]ui.Button = undefined;
                const list = targets(&buttons);
                const action = app.click(m, list);
                if (m.pressed and sheet == .none) {
                    const hit = app.pointer.pressed;
                    if (hit >= 100 and hit - 100 < count) {
                        // A press selects; the second press of a double
                        // click opens.
                        const i: usize = hit - 100;
                        if (m.double and selected == i) {
                            openEntry(i);
                        } else {
                            selected = i;
                            note = "";
                            if (pulp.desktop_profile) pulp.print("files: selected {s}\n", .{entries[i].nameSlice()});
                        }
                        changed = true;
                    } else if (hit == 0 and m.y >= 0 and m.y < BAR) {
                        // The toolbar's empty background moves the window.
                        app.win.requestMove();
                    } else if (hit == 0 and look == .closed and selected != null and m.x >= SIDEBAR_W) {
                        selected = null;
                        changed = true;
                    }
                }
                if (action != 0 and action < 100) changed = act(action) or changed;
            },
            else => {},
        };
        if (changed) {
            paint(whole());
        } else if (app.pointer.visualChanged(previous)) {
            if (sheet != .none) {
                paint(whole());
            } else {
                var buttons: [MAX_TARGETS]ui.Button = undefined;
                for (targets(&buttons)) |t| {
                    if ((previous.hover == t.id) == (app.pointer.hover == t.id) and (previous.pressed == t.id) == (app.pointer.pressed == t.id)) continue;
                    // The view switcher redraws as one control.
                    paint(if (t.id == 30 or t.id == 31) viewControl() else t.rect);
                }
            }
        }
        app.idle();
    }
}
