//! Text Editor (docs/design/014, M4): open, edit and save plain text.
//!
//! Documents are saved safely (a temporary file is written, made durable and
//! renamed over the original), a window with unsaved changes asks before it
//! closes, and a file that is not plain ASCII text is opened read-only
//! rather than risk damaging it. New documents are saved in Documents on
//! the /data disk.
const std = @import("std");
const pulp = @import("pulp");
const appkit = @import("appkit");
const ui = appkit.ui;
const K = appkit.K;
const proto = appkit.proto;
const buffer = @import("buffer.zig");

const BAR: i32 = ui.Metrics.toolbar_h;
const STATUS_H: i32 = 26;
const CELL_W: i32 = 8;
const LINE_H: i32 = 18;
const PAD_X: i32 = 16;
const PAD_Y: i32 = 12;
const CAPACITY: usize = 1024 * 1024;
const DOCUMENTS = "/data/Documents";

var app: appkit.App = undefined;
var buf: buffer.Buffer = undefined;
var clipboard: [64 * 1024]u8 = undefined;
var clipboard_len: usize = 0;

var path_buf: [256]u8 = undefined;
var path_len: usize = 0;
/// Why the document cannot be edited (a binary file, a file too large).
var locked: ?[]const u8 = null;
var top_line: usize = 0;
var left_col: usize = 0;
var selecting = false;
var status_note: []const u8 = "";
var status_bad = false;

const SheetKind = enum { none, save_as, unsaved };
var sheet: SheetKind = .none;
var quit_after_save = false;
var name_input: ui.TextInput(60) = .{};
var sheet_error: []const u8 = "";

fn path() []const u8 {
    return path_buf[0..path_len];
}
fn docName() []const u8 {
    return if (path_len == 0) "Untitled" else appkit.basename(path());
}
/// True when the data disk is attached (Documents can be made on it).
fn hasData() bool {
    pulp.mkdir(DOCUMENTS) catch {};
    return pulp.exists(DOCUMENTS);
}

// ── Layout ────────────────────────────────────────────────────────────────

fn textArea() ui.Rect {
    return .{ .x = 0, .y = BAR, .w = app.width(), .h = app.height() - BAR - STATUS_H };
}
fn visibleLines() usize {
    return @intCast(@max(1, @divTrunc(textArea().h - PAD_Y, LINE_H)));
}
fn visibleCols() usize {
    return @intCast(@max(1, @divTrunc(textArea().w - PAD_X * 2, CELL_W)));
}
fn saveButton() ui.Rect {
    return .{ .x = app.width() - 16 - 72, .y = 13, .w = 72, .h = ui.Metrics.push_small_h - 1 };
}
fn sheetLayout() ui.Sheet {
    return ui.Sheet.layout(app.width(), app.height(), if (sheet == .unsaved) 3 else 2, sheet == .save_as);
}

/// Scroll so the caret is on screen.
fn follow() void {
    const line = buf.lineOf(buf.caret);
    const rows = visibleLines();
    if (line < top_line) top_line = line;
    if (line >= top_line + rows) top_line = line + 1 - rows;
    const col = buf.column(buf.caret);
    const cols = visibleCols();
    if (col < left_col) left_col = col;
    if (col >= left_col + cols) left_col = col + 1 - cols;
    clampScroll();
}
fn clampScroll() void {
    const lines = buf.lineCount();
    const rows = visibleLines();
    top_line = @min(top_line, lines -| @min(rows, lines));
}

// ── Files ─────────────────────────────────────────────────────────────────

fn setPath(p: []const u8) void {
    path_len = @min(p.len, path_buf.len);
    std.mem.copyForwards(u8, path_buf[0..path_len], p[0..path_len]);
    app.win.setTitle(docName());
}

fn openFile(p: []const u8) void {
    locked = null;
    status_note = "";
    top_line = 0;
    left_col = 0;
    setPath(p);
    var truncated = false;
    const got = appkit.readFile(p, buf.bytes, &truncated) orelse {
        _ = buf.load("");
        locked = "This file could not be read.";
        pulp.print("editor: cannot read {s}\n", .{p});
        return;
    };
    if (truncated) {
        _ = buf.load("");
        locked = "This file is larger than 1 MB, which this editor does not open.";
        return;
    }
    if (buffer.problemWith(got)) |why| {
        // Shown, never changed: saving could damage what cannot be shown.
        buf.len = 0;
        locked = why;
        pulp.print("editor: {s} is read-only: {s}\n", .{ p, why });
        return;
    }
    buf.len = buffer.normalizeNewlines(buf.bytes[0..got.len]);
    buf.caret = 0;
    buf.anchor = null;
    buf.dirty = false;
    pulp.print("editor: opened {s}, {d} bytes\n", .{ p, buf.len });
}

/// Write the document to `target`; true when it is safely on the disk.
fn writeTo(target: []const u8) bool {
    if (!appkit.writeFileAtomic(target, buf.text())) return false;
    buf.dirty = false;
    setPath(target);
    status_note = "Saved.";
    status_bad = false;
    pulp.print("editor: saved {s}, {d} bytes\n", .{ target, buf.len });
    app.win.notify("Saved", docName());
    return true;
}

/// Save in place when the file is on the data disk; otherwise ask for a
/// name in Documents. True when the document is saved now.
fn save() bool {
    if (locked != null) return false;
    if (path_len > 0 and std.mem.startsWith(u8, path(), "/data/")) {
        if (writeTo(path())) return true;
        status_note = "The document could not be saved.";
        status_bad = true;
        return false;
    }
    openSaveAs();
    return false;
}

fn openSaveAs() void {
    sheet_error = "";
    name_input.set(if (path_len == 0) "Untitled.txt" else docName());
    sheet = .save_as;
}

fn confirmSaveAs() void {
    const name = name_input.text();
    if (name.len == 0 or name[0] == '.' or name[0] == ' ' or std.mem.indexOfScalar(u8, name, '/') != null) {
        sheet_error = "Type a name without a slash or a leading dot.";
        return;
    }
    if (!hasData()) {
        sheet_error = "No data disk is attached, so nothing can be saved.";
        return;
    }
    var target_buf: [200]u8 = undefined;
    // Plain text gets .txt unless a type was typed.
    const target = std.fmt.bufPrint(&target_buf, "{s}/{s}{s}", .{ DOCUMENTS, name, if (std.mem.indexOfScalar(u8, name, '.') == null) ".txt" else "" }) catch {
        sheet_error = "That name is too long.";
        return;
    };
    if (!std.mem.eql(u8, target, path()) and pulp.exists(target)) {
        sheet_error = "Documents already has a file with that name.";
        return;
    }
    if (!writeTo(target)) {
        sheet_error = "The document could not be saved.";
        return;
    }
    sheet = .none;
    if (quit_after_save) app.quit();
}

// ── Editing ───────────────────────────────────────────────────────────────

fn copySelection() void {
    const r = buf.selection() orelse return;
    clipboard_len = @min(r.end - r.start, clipboard.len);
    @memcpy(clipboard[0..clipboard_len], buf.bytes[r.start..][0..clipboard_len]);
}

fn typed(text: []const u8) void {
    if (locked != null) return;
    if (!buf.insert(text)) {
        status_note = "The document is full (1 MB).";
        status_bad = true;
    } else status_note = "";
}

/// Menu items and their shortcuts share these numbers.
fn command(id: u32) void {
    switch (id) {
        1 => _ = save(),
        2 => if (locked == null) openSaveAs(),
        3 => requestClose(),
        10 => buf.selectAll(),
        11 => copySelection(),
        12 => if (locked == null) {
            copySelection();
            _ = buf.deleteSelection();
        },
        13 => typed(clipboard[0..clipboard_len]),
        else => {},
    }
}

fn requestClose() void {
    if (buf.dirty and locked == null) {
        sheet = .unsaved;
        sheet_error = "";
        return;
    }
    app.quit();
}

fn key(k: appkit.Key) void {
    if (!k.down) return;
    if (sheet == .save_as) {
        if (k.code == K.esc) {
            sheet = .none;
            quit_after_save = false;
        } else if (k.code == K.enter) {
            confirmSaveAs();
        } else if (k.ch != 0) {
            sheet_error = "";
            _ = name_input.insert(k.ch);
        } else _ = name_input.editKey(k.code);
        return;
    }
    if (sheet == .unsaved) {
        if (k.code == K.esc) sheet = .none;
        if (k.code == K.enter) sheetButton(2);
        return;
    }
    if (k.ctrl) {
        switch (k.code) {
            0x1F => command(1), // S
            0x1E => command(10), // A
            0x2E => command(11), // C
            0x2D => command(12), // X
            0x2F => command(13), // V
            K.left => buf.move(.word_left, k.shift),
            K.right => buf.move(.word_right, k.shift),
            K.home => buf.move(.doc_start, k.shift),
            K.end => buf.move(.doc_end, k.shift),
            else => return,
        }
        follow();
        return;
    }
    switch (k.code) {
        K.left => buf.move(.left, k.shift),
        K.right => buf.move(.right, k.shift),
        K.up => buf.move(.up, k.shift),
        K.down => buf.move(.down, k.shift),
        K.home => buf.move(.line_start, k.shift),
        K.end => buf.move(.line_end, k.shift),
        K.page_up => buf.movePage(visibleLines() - 1, false, k.shift),
        K.page_down => buf.movePage(visibleLines() - 1, true, k.shift),
        K.backspace => if (locked == null) {
            _ = buf.backspace();
        },
        K.delete => if (locked == null and k.extended) {
            _ = buf.deleteForward();
        },
        K.enter => typed("\n"),
        K.tab => typed("    "),
        else => {
            if (k.ch == 0) return;
            typed(&[_]u8{k.ch});
        },
    }
    follow();
}

fn positionAt(x: i32, y: i32) usize {
    const area = textArea();
    const row: usize = @intCast(@max(0, @divTrunc(y - area.y - PAD_Y, LINE_H)));
    const col: usize = @intCast(@max(0, @divTrunc(x - PAD_X + @divTrunc(CELL_W, 2), CELL_W)));
    const line = @min(top_line + row, buf.lineCount() - 1);
    return buf.atColumn(buf.startOfLine(line), left_col + col);
}

fn sheetButton(i: usize) void {
    if (sheet == .save_as) {
        if (i == 0) {
            sheet = .none;
            quit_after_save = false;
        } else confirmSaveAs();
        return;
    }
    // Unsaved changes: Don't Save, Cancel, Save.
    switch (i) {
        0 => app.quit(),
        1 => sheet = .none,
        else => {
            sheet = .none;
            quit_after_save = true;
            if (save()) app.quit();
        },
    }
}

// ── Drawing ───────────────────────────────────────────────────────────────

fn paint() void {
    var s = app.surface();
    const W = app.width();
    const H = app.height();
    const T = ui.Tone;
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = H }, 0xFFFFFF);
    // Toolbar: the window buttons are at the left; then the document.
    s.fill(.{ .x = 0, .y = 0, .w = W, .h = BAR }, T.toolbar);
    s.fill(.{ .x = 0, .y = BAR - 1, .w = W, .h = 1 }, T.hairline);
    const save_rect = saveButton();
    const name_room = save_rect.x - 16 - ui.Metrics.buttons_w;
    var name_buf: [140]u8 = undefined;
    const name = ui.elide(&name_buf, docName(), @max(0, name_room - 70));
    ui.label(&s, name, ui.Metrics.buttons_w, 22, 1, T.text);
    if (buf.dirty) ui.label(&s, "Edited", ui.Metrics.buttons_w + ui.textWidth(name, 1) + 10, 22, 1, T.placeholder);
    var st = ui.ControlState.of(app.pointer, 1);
    st.enabled = locked == null;
    ui.pushButton(&s, save_rect, "Save", buf.dirty and locked == null, st);

    const area = textArea();
    s.setClip(area);
    if (locked) |why| {
        ui.icon(&s, .document, @divTrunc(W - 64, 2), area.y + 48, 64);
        const shown = ui.fitting(why, W - 48);
        ui.label(&s, shown, @divTrunc(W - ui.textWidth(shown, 1), 2), area.y + 132, 1, 0xB05251);
    } else {
        const rows = visibleLines();
        const cols = visibleCols();
        const sel = buf.selection();
        var pos = buf.startOfLine(top_line);
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            const end = buf.lineEnd(pos);
            const y = area.y + PAD_Y + @as(i32, @intCast(row)) * LINE_H;
            // Tabs become spaces up to their stop; then the window's columns.
            var line: [512]u8 = undefined;
            var used: usize = 0;
            var col: usize = 0;
            // The part of the selection on this line; a selected line end
            // shows as one extra cell.
            var sel_from: ?usize = null;
            var sel_to: usize = 0;
            if (sel) |r| if (r.start <= end and r.end > pos or (r.start <= end and r.end > end)) {
                sel_from = buf.column(@max(r.start, pos));
                sel_to = if (r.end > end) buf.column(end) + 1 else buf.column(r.end);
            };
            var i = pos;
            while (i < end) : (i += 1) {
                const next = buffer.advance(col, buf.bytes[i]);
                while (col < next) : (col += 1) {
                    if (col >= left_col and col - left_col < cols and used < line.len) {
                        line[used] = if (buf.bytes[i] == '\t') ' ' else buf.bytes[i];
                        used += 1;
                    }
                }
            }
            if (sel_from) |from| if (sel_to > from) {
                const a = from -| left_col;
                const b = @min(sel_to -| left_col, cols + 1);
                if (b > a) s.fill(.{ .x = PAD_X + @as(i32, @intCast(a)) * CELL_W, .y = y - 4, .w = @as(i32, @intCast(b - a)) * CELL_W, .h = LINE_H }, T.accent_soft);
            };
            ui.monoLabel(&s, line[0..used], PAD_X, y, 0x2B2E34);
            if (buf.caret >= pos and buf.caret <= end and sheet == .none) {
                const caret_col = buf.column(buf.caret);
                if (caret_col >= left_col and caret_col - left_col <= cols)
                    s.fill(.{ .x = PAD_X + @as(i32, @intCast(caret_col - left_col)) * CELL_W, .y = y - 4, .w = 2, .h = LINE_H }, T.accent);
            }
            if (end >= buf.len) break;
            pos = end + 1;
        }
    }
    s.setClip(.{ .x = 0, .y = 0, .w = W, .h = H });
    // Status bar: where the caret is, or what just happened.
    s.fill(.{ .x = 0, .y = H - STATUS_H, .w = W, .h = STATUS_H }, T.toolbar);
    s.fill(.{ .x = 0, .y = H - STATUS_H, .w = W, .h = 1 }, T.hairline);
    var text_buf: [96]u8 = undefined;
    const where = std.fmt.bufPrint(&text_buf, "Line {d}, Column {d}  /  {d} characters", .{ buf.lineOf(buf.caret) + 1, buf.column(buf.caret) + 1, buf.len }) catch "";
    const left = if (status_note.len > 0) status_note else if (locked != null) "Read-only" else where;
    ui.label(&s, ui.fitting(left, W - 32), 16, H - STATUS_H + 9, 1, if (status_note.len > 0 and status_bad) 0xB05251 else T.secondary);

    if (sheet != .none) {
        const layout = sheetLayout();
        var msg_buf: [120]u8 = undefined;
        if (sheet == .save_as) {
            const labels = [_][]const u8{ "Cancel", "Save" };
            layout.paint(&s, W, H, "Save in Documents", if (sheet_error.len > 0) sheet_error else "Name of the document:", &labels, app.pointer, 50);
            ui.textField(&s, layout.field, name_input.text(), name_input.caret, true, false, "");
        } else {
            const labels = [_][]const u8{ "Don't Save", "Cancel", "Save" };
            const msg = std.fmt.bufPrint(&msg_buf, "\"{s}\" has changes that are not saved.", .{ui.fitting(docName(), 200)}) catch "";
            layout.paint(&s, W, H, "Save the changes?", msg, &labels, app.pointer, 50);
        }
    }
    app.presentAll();
    if (pulp.desktop_profile) pulp.puts("editor: painted\n");
}

const MENU =
    "MFile\n" ++
    "I1 Save\tCtrl+S\n" ++
    "I2 Save As...\n" ++
    "-\n" ++
    "I3 Close\n" ++
    "MEdit\n" ++
    "I12 Cut\tCtrl+X\n" ++
    "I11 Copy\tCtrl+C\n" ++
    "I13 Paste\tCtrl+V\n" ++
    "-\n" ++
    "I10 Select All\tCtrl+A\n";

export fn _start() callconv(.c) noreturn {
    app = appkit.App.open(.{
        .title = "Untitled",
        .app = proto.App.editor,
        .width = 640,
        .height = 460,
        .x = 330,
        .y = 120,
        .min_w = 380,
        .min_h = 240,
        .bar_height = BAR,
        .confirms_close = true,
        .menu = MENU,
    });
    const memory = pulp.mapMemory(CAPACITY, .read_write) catch pulp.exit(1);
    buf = .{ .bytes = memory };
    pulp.puts("editor: new document\n");
    paint();
    while (true) {
        var dirty = false;
        while (app.next()) |event| {
            var redraw = true;
            defer dirty = dirty or redraw;
            switch (event) {
                .close => requestClose(),
                .resized => follow(),
                .menu => |id| {
                    command(id);
                    follow();
                },
                .open_file => |p| openFile(p),
                .key => |k| {
                    if (k.down) key(k) else redraw = false;
                },
                .wheel => |steps| {
                    const lines: usize = @intCast(@abs(steps) * 3);
                    top_line = if (steps > 0) top_line + lines else top_line -| lines;
                    clampScroll();
                },
                .mouse => |m| {
                    const before = app.pointer;
                    var targets: [4]ui.Button = undefined;
                    var n: usize = 0;
                    if (sheet != .none) {
                        const layout = sheetLayout();
                        for (0..layout.count) |i| {
                            targets[n] = .{ .id = @intCast(50 + i), .rect = layout.buttons[i] };
                            n += 1;
                        }
                    } else {
                        targets[0] = .{ .id = 1, .rect = saveButton() };
                        n = 1;
                    }
                    const action = app.click(m, targets[0..n]);
                    redraw = app.pointer.visualChanged(before);
                    if (action == 1) {
                        _ = save();
                        redraw = true;
                    } else if (action >= 50) {
                        sheetButton(action - 50);
                        redraw = true;
                    } else if (sheet == .none and locked == null) {
                        const area = textArea();
                        if (m.pressed and area.contains(m.x, m.y)) {
                            const at = positionAt(m.x, m.y);
                            if (m.double) {
                                // A double click selects the word.
                                buf.caret = at;
                                buf.move(.word_left, false);
                                buf.move(.word_right, true);
                            } else {
                                buf.caret = at;
                                buf.anchor = at;
                                buf.wanted_col = null;
                                selecting = true;
                            }
                            redraw = true;
                        } else if (selecting and m.buttons & 1 != 0) {
                            const at = positionAt(m.x, m.y);
                            if (at != buf.caret) {
                                buf.caret = at;
                                follow();
                                redraw = true;
                            }
                        } else if (m.pressed and app.pointer.pressed == 0 and m.y >= 0 and m.y < BAR) {
                            app.win.requestMove();
                        }
                        if (m.released) selecting = false;
                    } else if (sheet == .none and m.pressed and app.pointer.pressed == 0 and m.y >= 0 and m.y < BAR) {
                        app.win.requestMove();
                    }
                },
                else => {},
            }
        }
        if (dirty) paint();
        app.idle();
    }
}
