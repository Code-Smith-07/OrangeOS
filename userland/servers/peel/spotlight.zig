//! Spotlight: type to find an app, an open window or a desktop action, or to
//! work out a sum (docs/design/014, M1).
//!
//! Pure logic: no drawing, no processes. Peel owns the query, paints the
//! results and runs the chosen one. Matching is case-insensitive and ranks
//! a title that starts with the query above a word that does, above a title
//! that merely contains it, above a keyword ("web" finds the browser).

const std = @import("std");

/// Artwork for a result; desktop.zig maps each to an atlas icon.
pub const Glyph = enum { files, welcome, terminal, clock, about, browser, controls, trash, appearance, windows, desktop, calendar, calculator, editor, viewer, settings, lock, document, folder, image };

pub const Target = union(enum) {
    none,
    /// Peel's application index (launchApp).
    app: usize,
    /// A desktop.Action value.
    action: u16,
    /// An open window, by its stable id.
    window: u32,
    /// A file or folder: its index in the list given to search().
    file: u16,
};

pub const Kind = enum { calculation, app, action, window, file };

pub const Result = struct {
    kind: Kind,
    title: []const u8,
    subtitle: []const u8,
    glyph: Glyph,
    target: Target,
    score: u16 = 0,
};

pub const MAX_RESULTS = 6;
pub const MAX_QUERY = 40;
/// How many files search() looks at.
pub const MAX_FILES = 64;

/// The action numbers Spotlight can run, mirrored from desktop.Action so this
/// file stays testable on its own (desktop.zig asserts they agree).
pub const actions = struct {
    pub const overview: u16 = 5;
    pub const settings: u16 = 6;
    pub const desktop: u16 = 8;
    pub const new_terminal: u16 = 9;
    pub const calendar: u16 = 13;
    pub const wallpaper: u16 = 20;
    pub const lock: u16 = 31;
    pub const notifications: u16 = 30;
};

const Entry = struct {
    result: Result,
    keywords: []const u8,
};

fn app(title: []const u8, subtitle: []const u8, glyph: Glyph, index: usize, keywords: []const u8) Entry {
    return .{ .result = .{ .kind = .app, .title = title, .subtitle = subtitle, .glyph = glyph, .target = .{ .app = index } }, .keywords = keywords };
}
fn act(title: []const u8, subtitle: []const u8, glyph: Glyph, action: u16, keywords: []const u8) Entry {
    return .{ .result = .{ .kind = .action, .title = title, .subtitle = subtitle, .glyph = glyph, .target = .{ .action = action } }, .keywords = keywords };
}

const catalog = [_]Entry{
    app("Files", "Application", .files, 4, "finder documents folders browse disk"),
    app("Orange Browser", "Application", .browser, 7, "web internet www safari website search youtube"),
    app("Terminal", "Application", .terminal, 1, "shell console command line squeeze juice"),
    app("Clock", "Application", .clock, 2, "time watch"),
    app("Welcome", "Application", .welcome, 0, "home start launch grove"),
    app("About Orange OS", "Application", .about, 3, "version system information"),
    app("Control Center", "Wi-Fi, Bluetooth, sound and display", .controls, 6, "wifi bluetooth sound volume brightness display battery network"),
    app("Trash", "Application", .trash, 5, "bin deleted recycle"),
    app("Text Editor", "Application", .editor, 8, "write notes document textedit notepad edit"),
    app("Image Viewer", "Application", .viewer, 9, "preview photo picture png bmp"),
    app("Calculator", "Application", .calculator, 10, "sum maths add numbers"),
    app("Settings", "Application", .settings, 11, "preferences system display sound network bluetooth keyboard password users"),
    act("Lock Screen", "Ask for the password again", .lock, actions.lock, "password sign out security"),
    act("Notifications", "Recent notifications", .controls, actions.notifications, "alerts banners bell"),
    act("Appearance", "Theme and wallpaper", .appearance, actions.settings, "settings preferences wallpaper theme background colours"),
    act("Mission Control", "See all open windows", .windows, actions.overview, "windows overview expose switch"),
    act("Show Desktop", "Hide or bring back all windows", .desktop, actions.desktop, "desktop hide minimise"),
    act("New Terminal Window", "Terminal", .terminal, actions.new_terminal, "shell console"),
    act("Calendar", "This month", .calendar, actions.calendar, "date today month day"),
    act("Coastal Glass", "Theme", .appearance, actions.wallpaper + 0, "theme wallpaper light blue sea"),
    act("Citrus Atelier", "Theme", .appearance, actions.wallpaper + 1, "theme wallpaper light orange warm"),
    act("Midnight Aurora", "Theme", .appearance, actions.wallpaper + 2, "theme wallpaper dark mode night"),
};

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

fn startsWithFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, haystack[0..needle.len]) |a, b| if (lower(a) != lower(b)) return false;
    return true;
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) if (startsWithFold(haystack[i..], needle)) return true;
    return false;
}

/// A word (after a space, hyphen or the start) that begins with `needle`.
fn wordStartsWith(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i < haystack.len) : (i += 1) {
        if ((i == 0 or haystack[i - 1] == ' ' or haystack[i - 1] == '-') and startsWithFold(haystack[i..], needle)) return true;
    }
    return false;
}

/// 0 when the text does not match at all.
pub fn score(title: []const u8, keywords: []const u8, query: []const u8) u16 {
    if (query.len == 0) return 0;
    if (startsWithFold(title, query)) return 400 - @as(u16, @intCast(@min(title.len, 100)));
    if (wordStartsWith(title, query)) return 300 - @as(u16, @intCast(@min(title.len, 100)));
    if (query.len >= 2 and containsFold(title, query)) return 200;
    if (query.len >= 2 and wordStartsWith(keywords, query)) return 100;
    return 0;
}

/// Leading and trailing spaces never change what is found.
pub fn trim(query: []const u8) []const u8 {
    return std.mem.trim(u8, query, " ");
}

pub const OpenWindow = struct { id: u32, title: []const u8, glyph: Glyph };

/// A file or folder Spotlight may offer (from the Documents folder).
pub const FileEntry = struct { name: []const u8, where: []const u8, glyph: Glyph };

/// The icon for a file, from its name.
pub fn fileGlyph(name: []const u8, is_dir: bool) Glyph {
    if (is_dir) return .folder;
    for ([_][]const u8{ ".png", ".bmp", ".ppm" }) |ext| {
        if (name.len > ext.len and startsWithFold(name[name.len - ext.len ..], ext)) return .image;
    }
    return .document;
}

/// Fill `out` with the best matches, best first; returns how many. A sum
/// (when the query is one) comes first, then apps, actions and windows by
/// score. `number_buf` holds the sum's text and must outlive the results.
pub fn search(raw_query: []const u8, windows: []const OpenWindow, files: []const FileEntry, out: *[MAX_RESULTS]Result, number_buf: *[48]u8) usize {
    const query = trim(raw_query);
    var count: usize = 0;
    if (query.len == 0) return 0;
    if (calculate(query)) |value| {
        out[0] = .{ .kind = .calculation, .title = formatNumber(number_buf, value), .subtitle = "Calculator", .glyph = .calculator, .target = .none, .score = 1000 };
        count = 1;
    }
    var candidates: [catalog.len + 8 + MAX_FILES]Result = undefined;
    var n: usize = 0;
    for (catalog) |entry| {
        const s = score(entry.result.title, entry.keywords, query);
        if (s == 0) continue;
        candidates[n] = entry.result;
        candidates[n].score = s;
        n += 1;
    }
    for (windows[0..@min(windows.len, 8)]) |w| {
        // Windows rank a little below an app of the same name, so "term"
        // offers the Terminal app first and its open window next.
        const s = score(w.title, "", query);
        if (s == 0) continue;
        candidates[n] = .{ .kind = .window, .title = w.title, .subtitle = "Open window", .glyph = w.glyph, .target = .{ .window = w.id }, .score = s - 1 };
        n += 1;
    }
    for (files[0..@min(files.len, MAX_FILES)], 0..) |f, i| {
        // Files rank below apps and windows of the same name.
        const s = score(f.name, "", query);
        if (s < 3) continue;
        candidates[n] = .{ .kind = .file, .title = f.name, .subtitle = f.where, .glyph = f.glyph, .target = .{ .file = @intCast(i) }, .score = s - 2 };
        n += 1;
    }
    std.sort.insertion(Result, candidates[0..n], {}, struct {
        fn before(_: void, a: Result, b: Result) bool {
            if (a.score != b.score) return a.score > b.score;
            return @intFromEnum(a.kind) < @intFromEnum(b.kind);
        }
    }.before);
    for (candidates[0..n]) |r| {
        if (count == MAX_RESULTS) break;
        out[count] = r;
        count += 1;
    }
    return count;
}

// ── Calculator ───────────────────────────────────────────────────────────

/// The value of an arithmetic query such as "12*7+3", "(2+3)/4" or "2^10";
/// null when the query is not arithmetic (a plain number is not a sum).
pub fn calculate(query: []const u8) ?f64 {
    var has_operator = false;
    var has_digit = false;
    for (query, 0..) |c, i| switch (c) {
        '0'...'9' => has_digit = true,
        '+', '*', '/', '^', '%', 'x' => has_operator = true,
        '-' => has_operator = has_operator or i > 0,
        '.', ' ', '(', ')' => {},
        else => return null,
    };
    if (!has_operator or !has_digit) return null;
    var p = Parser{ .text = query };
    const value = p.expression() orelse return null;
    p.skip();
    if (p.at != p.text.len or std.math.isNan(value) or std.math.isInf(value)) return null;
    return value;
}

const Parser = struct {
    text: []const u8,
    at: usize = 0,
    depth: u8 = 0,

    fn skip(p: *Parser) void {
        while (p.at < p.text.len and p.text[p.at] == ' ') p.at += 1;
    }
    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.at < p.text.len) p.text[p.at] else 0;
    }
    fn expression(p: *Parser) ?f64 {
        var value = p.term() orelse return null;
        while (true) switch (p.peek()) {
            '+' => {
                p.at += 1;
                value += p.term() orelse return null;
            },
            '-' => {
                p.at += 1;
                value -= p.term() orelse return null;
            },
            else => return value,
        };
    }
    fn term(p: *Parser) ?f64 {
        var value = p.power() orelse return null;
        while (true) switch (p.peek()) {
            '*', 'x' => {
                p.at += 1;
                value *= p.power() orelse return null;
            },
            '/' => {
                p.at += 1;
                const d = p.power() orelse return null;
                if (d == 0) return null;
                value /= d;
            },
            '%' => {
                p.at += 1;
                const d = p.power() orelse return null;
                if (d == 0) return null;
                value = @rem(value, d);
            },
            else => return value,
        };
    }
    fn power(p: *Parser) ?f64 {
        const base = p.unary() orelse return null;
        if (p.peek() != '^') return base;
        p.at += 1;
        const exponent = p.power() orelse return null; // right-associative
        if (@abs(exponent) > 1024) return null;
        return std.math.pow(f64, base, exponent);
    }
    fn unary(p: *Parser) ?f64 {
        if (p.peek() == '-') {
            p.at += 1;
            return -(p.unary() orelse return null);
        }
        return p.primary();
    }
    fn primary(p: *Parser) ?f64 {
        if (p.peek() == '(') {
            if (p.depth == 16) return null;
            p.at += 1;
            p.depth += 1;
            const value = p.expression() orelse return null;
            p.depth -= 1;
            if (p.peek() != ')') return null;
            p.at += 1;
            return value;
        }
        const start = p.at;
        while (p.at < p.text.len and (std.ascii.isDigit(p.text[p.at]) or p.text[p.at] == '.')) p.at += 1;
        if (p.at == start) return null;
        return std.fmt.parseFloat(f64, p.text[start..p.at]) catch null;
    }
};

/// "87", "0.333333333", "-2.5", "1.5e+20": whole numbers without a point,
/// others to nine decimals with trailing zeros removed.
pub fn formatNumber(buf: *[48]u8, value: f64) []const u8 {
    if (@abs(value) >= 1e15) return std.fmt.bufPrint(buf, "{e}", .{value}) catch "?";
    if (value == @trunc(value)) return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(value))}) catch "?";
    var text = std.fmt.bufPrint(buf, "{d:.9}", .{value}) catch return "?";
    while (text.len > 0 and text[text.len - 1] == '0') text = text[0 .. text.len - 1];
    if (text.len > 0 and text[text.len - 1] == '.') text = text[0 .. text.len - 1];
    return text;
}

// ── Tests (zig test userland/servers/peel/spotlight.zig) ──────────────────

fn find(query: []const u8, windows: []const OpenWindow) []const Result {
    const S = struct {
        var out: [MAX_RESULTS]Result = undefined;
        var buf: [48]u8 = undefined;
    };
    const n = search(query, windows, &.{}, &S.out, &S.buf);
    return S.out[0..n];
}

test "an app is found by the start of its name, any case" {
    const r = find("TER", &.{});
    try std.testing.expectEqualStrings("Terminal", r[0].title);
    try std.testing.expectEqual(Target{ .app = 1 }, r[0].target);
}

test "a word inside the name and a keyword both find it" {
    try std.testing.expectEqualStrings("Orange Browser", find("brow", &.{})[0].title);
    try std.testing.expectEqualStrings("Orange Browser", find("web", &.{})[0].title);
    try std.testing.expectEqualStrings("Appearance", find("wallpaper", &.{})[0].title);
    try std.testing.expectEqualStrings("Control Center", find("wifi", &.{})[0].title);
}

test "an empty or blank query finds nothing, a nonsense query nothing" {
    try std.testing.expectEqual(@as(usize, 0), find("", &.{}).len);
    try std.testing.expectEqual(@as(usize, 0), find("   ", &.{}).len);
    try std.testing.expectEqual(@as(usize, 0), find("zzqx", &.{}).len);
}

test "one letter matches name starts only, not keywords" {
    for (find("c", &.{})) |r| try std.testing.expect(startsWithFold(r.title, "c") or wordStartsWith(r.title, "c"));
}

test "open windows are found, after the app of the same name" {
    const windows = [_]OpenWindow{.{ .id = 7, .title = "Squeeze - juice", .glyph = .terminal }};
    const r = find("squ", &windows);
    try std.testing.expectEqual(Target{ .window = 7 }, r[0].target);
    try std.testing.expectEqual(Kind.window, r[0].kind);
    const t = find("files", &[_]OpenWindow{.{ .id = 3, .title = "Files", .glyph = .files }});
    try std.testing.expectEqual(Kind.app, t[0].kind);
    try std.testing.expectEqual(Target{ .window = 3 }, t[1].target);
}

test "dark finds the dark theme first" {
    try std.testing.expectEqualStrings("Midnight Aurora", find("dark", &.{})[0].title);
}

test "results never exceed the limit" {
    try std.testing.expect(find("e", &.{}).len <= MAX_RESULTS);
}

test "sums are worked out and shown first" {
    const r = find("12*7+3", &.{});
    try std.testing.expectEqualStrings("87", r[0].title);
    try std.testing.expectEqual(Kind.calculation, r[0].kind);
    try std.testing.expectEqualStrings("2.5", find("(2+3)/2", &.{})[0].title);
    try std.testing.expectEqualStrings("1024", find("2^10", &.{})[0].title);
    try std.testing.expectEqualStrings("-6", find("-2*3", &.{})[0].title);
    try std.testing.expectEqualStrings("0.333333333", find("1/3", &.{})[0].title);
    try std.testing.expectEqualStrings("1", find("10 % 3", &.{})[0].title);
    try std.testing.expectEqualStrings("12", find("3x4", &.{})[0].title);
}

test "not a sum: plain numbers, broken or unsafe expressions" {
    for ([_][]const u8{ "42", "-5", "1/0", "2+", "(1+2", "1+2)", "2^99999", "1e5+1", "((((((((((((((((((1))))))))))))))))))+1", "files" }) |q|
        try std.testing.expect(calculate(q) == null);
}

test "files are found by name, below apps of the same name" {
    var out: [MAX_RESULTS]Result = undefined;
    var buf: [48]u8 = undefined;
    const files = [_]FileEntry{
        .{ .name = "notes.txt", .where = "Documents", .glyph = fileGlyph("notes.txt", false) },
        .{ .name = "Files report.txt", .where = "Documents", .glyph = .document },
        .{ .name = "Holiday.PNG", .where = "Documents", .glyph = fileGlyph("Holiday.PNG", false) },
        .{ .name = "Projects", .where = "Documents", .glyph = fileGlyph("Projects", true) },
    };
    var n = search("notes", &.{}, &files, &out, &buf);
    // The file itself first, then Text Editor (its keyword is "notes").
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Kind.file, out[0].kind);
    try std.testing.expectEqual(@as(u16, 0), out[0].target.file);
    n = search("files", &.{}, &files, &out, &buf);
    try std.testing.expectEqualStrings("Files", out[0].title);
    try std.testing.expectEqualStrings("Files report.txt", out[1].title);
    n = search("holi", &.{}, &files, &out, &buf);
    try std.testing.expectEqual(Glyph.image, out[0].glyph);
    n = search("proj", &.{}, &files, &out, &buf);
    try std.testing.expectEqual(Glyph.folder, out[0].glyph);
    try std.testing.expectEqualStrings("Settings", blk: {
        _ = search("sett", &.{}, &files, &out, &buf);
        break :blk out[0].title;
    });
}
