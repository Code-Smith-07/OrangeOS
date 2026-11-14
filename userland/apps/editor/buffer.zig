//! The Text Editor's document: bytes, a caret, an optional selection, and
//! the arithmetic that turns them into lines and columns. No drawing and no
//! files, so every edit and movement is unit tested.
//!
//! Text is plain ASCII with newlines; a tab advances to the next multiple of
//! four columns. Positions are byte offsets; columns are what the eye sees.
const std = @import("std");

pub const TAB: usize = 4;

pub const Move = enum { left, right, up, down, line_start, line_end, doc_start, doc_end, word_left, word_right };

pub const Buffer = struct {
    bytes: []u8,
    len: usize = 0,
    caret: usize = 0,
    /// The other end of the selection, when there is one.
    anchor: ?usize = null,
    /// The column Up and Down try to keep, as on any editor.
    wanted_col: ?usize = null,
    /// Changed since it was last saved or loaded.
    dirty: bool = false,

    pub fn text(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn load(self: *Buffer, content: []const u8) bool {
        if (content.len > self.bytes.len) return false;
        @memcpy(self.bytes[0..content.len], content);
        self.len = content.len;
        self.caret = 0;
        self.anchor = null;
        self.wanted_col = null;
        self.dirty = false;
        return true;
    }

    pub const Range = struct { start: usize, end: usize };
    pub fn selection(self: *const Buffer) ?Range {
        const a = self.anchor orelse return null;
        if (a == self.caret) return null;
        return .{ .start = @min(a, self.caret), .end = @max(a, self.caret) };
    }

    pub fn selectAll(self: *Buffer) void {
        self.anchor = 0;
        self.caret = self.len;
        self.wanted_col = null;
    }

    fn remove(self: *Buffer, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.bytes[start .. self.len - (end - start)], self.bytes[end..self.len]);
        self.len -= end - start;
        self.caret = start;
        self.anchor = null;
        self.dirty = true;
    }

    /// Delete the selection; false when there was none.
    pub fn deleteSelection(self: *Buffer) bool {
        const r = self.selection() orelse {
            self.anchor = null;
            return false;
        };
        self.remove(r.start, r.end);
        self.wanted_col = null;
        return true;
    }

    /// Type or paste: replaces the selection. False (and nothing changes)
    /// when the document would grow past its capacity.
    pub fn insert(self: *Buffer, new: []const u8) bool {
        const selected = if (self.selection()) |r| r.end - r.start else 0;
        if (self.len - selected + new.len > self.bytes.len) return false;
        _ = self.deleteSelection();
        std.mem.copyBackwards(u8, self.bytes[self.caret + new.len .. self.len + new.len], self.bytes[self.caret..self.len]);
        @memcpy(self.bytes[self.caret..][0..new.len], new);
        self.len += new.len;
        self.caret += new.len;
        self.wanted_col = null;
        self.dirty = true;
        return true;
    }

    pub fn backspace(self: *Buffer) bool {
        if (self.deleteSelection()) return true;
        if (self.caret == 0) return false;
        self.remove(self.caret - 1, self.caret);
        self.wanted_col = null;
        return true;
    }

    pub fn deleteForward(self: *Buffer) bool {
        if (self.deleteSelection()) return true;
        if (self.caret >= self.len) return false;
        self.remove(self.caret, self.caret + 1);
        self.wanted_col = null;
        return true;
    }

    pub fn lineStart(self: *const Buffer, pos: usize) usize {
        var i = @min(pos, self.len);
        while (i > 0 and self.bytes[i - 1] != '\n') i -= 1;
        return i;
    }
    pub fn lineEnd(self: *const Buffer, pos: usize) usize {
        var i = @min(pos, self.len);
        while (i < self.len and self.bytes[i] != '\n') i += 1;
        return i;
    }

    /// The visual column of `pos` on its line (tabs count to the next stop).
    pub fn column(self: *const Buffer, pos: usize) usize {
        var col: usize = 0;
        for (self.bytes[self.lineStart(pos)..@min(pos, self.len)]) |c| col = advance(col, c);
        return col;
    }

    /// The position on the line starting at `start` nearest to `col`.
    pub fn atColumn(self: *const Buffer, start: usize, col: usize) usize {
        var i = start;
        var at: usize = 0;
        while (i < self.len and self.bytes[i] != '\n') : (i += 1) {
            const next = advance(at, self.bytes[i]);
            // Inside a tab: the nearer side wins.
            if (next > col) return if (col - at < next - col) i else i + 1;
            at = next;
        }
        return i;
    }

    /// Zero-based line number of `pos`.
    pub fn lineOf(self: *const Buffer, pos: usize) usize {
        return std.mem.count(u8, self.bytes[0..@min(pos, self.len)], "\n");
    }
    pub fn lineCount(self: *const Buffer) usize {
        return std.mem.count(u8, self.text(), "\n") + 1;
    }
    /// Where line `line` starts (the end of the text when there are fewer).
    pub fn startOfLine(self: *const Buffer, line: usize) usize {
        var i: usize = 0;
        var n: usize = 0;
        while (n < line and i < self.len) : (i += 1) {
            if (self.bytes[i] == '\n') n += 1;
        }
        return i;
    }

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    /// Move the caret; with `select`, extend the selection from where it was.
    pub fn move(self: *Buffer, how: Move, select: bool) void {
        if (select) {
            if (self.anchor == null) self.anchor = self.caret;
        } else if (self.selection()) |r| {
            // Left and Right collapse a selection to its ends first.
            self.anchor = null;
            if (how == .left) {
                self.caret = r.start;
                self.wanted_col = null;
                return;
            }
            if (how == .right) {
                self.caret = r.end;
                self.wanted_col = null;
                return;
            }
        } else self.anchor = null;
        switch (how) {
            .left => self.caret -|= 1,
            .right => self.caret = @min(self.len, self.caret + 1),
            .line_start => self.caret = self.lineStart(self.caret),
            .line_end => self.caret = self.lineEnd(self.caret),
            .doc_start => self.caret = 0,
            .doc_end => self.caret = self.len,
            .word_left => {
                var i = self.caret;
                while (i > 0 and !isWord(self.bytes[i - 1])) i -= 1;
                while (i > 0 and isWord(self.bytes[i - 1])) i -= 1;
                self.caret = i;
            },
            .word_right => {
                var i = self.caret;
                while (i < self.len and !isWord(self.bytes[i])) i += 1;
                while (i < self.len and isWord(self.bytes[i])) i += 1;
                self.caret = i;
            },
            .up, .down => {
                const col = self.wanted_col orelse self.column(self.caret);
                const start = self.lineStart(self.caret);
                if (how == .up) {
                    if (start == 0) {
                        self.caret = 0;
                    } else self.caret = self.atColumn(self.lineStart(start - 1), col);
                } else {
                    const end = self.lineEnd(self.caret);
                    self.caret = if (end == self.len) self.len else self.atColumn(end + 1, col);
                }
                self.wanted_col = col;
                return;
            },
        }
        self.wanted_col = null;
    }

    /// Move up or down by `lines` (Page Up and Page Down).
    pub fn movePage(self: *Buffer, lines: usize, down: bool, select: bool) void {
        for (0..lines) |_| self.move(if (down) .down else .up, select);
    }
};

pub fn advance(col: usize, c: u8) usize {
    return if (c == '\t') (col / TAB + 1) * TAB else col + 1;
}

/// What stops a file from being edited here: null when it is plain text.
pub fn problemWith(content: []const u8) ?[]const u8 {
    for (content) |c| {
        if (c == 0 or (c < 32 and c != '\n' and c != '\r' and c != '\t') or c == 127) return "This file is not plain text.";
        if (c > 127) return "This file has characters outside plain English text (ASCII).";
    }
    return null;
}

/// Windows line endings (CR LF) become plain newlines; returns the new length.
pub fn normalizeNewlines(bytes: []u8) usize {
    var out: usize = 0;
    for (bytes, 0..) |c, i| {
        if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        bytes[out] = if (c == '\r') '\n' else c;
        out += 1;
    }
    return out;
}

const testing = std.testing;

fn make(storage: []u8, content: []const u8) Buffer {
    var b = Buffer{ .bytes = storage };
    std.debug.assert(b.load(content));
    return b;
}

test "typing, backspace and delete edit at the caret" {
    var store: [32]u8 = undefined;
    var b = make(&store, "");
    try testing.expect(b.insert("helo"));
    b.move(.left, false);
    try testing.expect(b.insert("l"));
    try testing.expectEqualStrings("hello", b.text());
    try testing.expectEqual(@as(usize, 4), b.caret);
    try testing.expect(b.backspace());
    try testing.expect(b.deleteForward());
    try testing.expectEqualStrings("hel", b.text());
    try testing.expect(!b.deleteForward());
    b.move(.doc_start, false);
    try testing.expect(!b.backspace());
    try testing.expect(b.dirty);
}

test "a full document refuses more text and stays unchanged" {
    var store: [8]u8 = undefined;
    var b = make(&store, "123456");
    b.move(.doc_end, false);
    try testing.expect(!b.insert("abc"));
    try testing.expectEqualStrings("123456", b.text());
    try testing.expect(b.insert("ab"));
    // Replacing a selection may fit even when plain typing would not.
    b.selectAll();
    try testing.expect(b.insert("12345678"));
    try testing.expectEqualStrings("12345678", b.text());
    try testing.expect(!b.load("123456789"));
}

test "selection: extend, replace, delete, and collapse to an end" {
    var store: [64]u8 = undefined;
    var b = make(&store, "one two three");
    b.move(.word_right, false);
    b.move(.right, false);
    b.move(.word_right, true);
    try testing.expectEqualStrings("two", b.text()[b.selection().?.start..b.selection().?.end]);
    try testing.expect(b.insert("2"));
    try testing.expectEqualStrings("one 2 three", b.text());
    try testing.expect(b.selection() == null);
    b.move(.doc_start, false);
    b.move(.line_end, true);
    b.move(.left, false); // collapses to the start
    try testing.expectEqual(@as(usize, 0), b.caret);
    b.selectAll();
    b.move(.right, false); // collapses to the end
    try testing.expectEqual(b.len, b.caret);
    b.selectAll();
    try testing.expect(b.backspace());
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "up and down keep the column across short lines" {
    var store: [64]u8 = undefined;
    var b = make(&store, "a long line\nab\n\nanother long one");
    b.caret = 8; // column 8 of line 0
    b.move(.down, false);
    try testing.expectEqual(@as(usize, 14), b.caret); // end of "ab"
    b.move(.down, false);
    try testing.expectEqual(@as(usize, 15), b.caret); // the empty line
    b.move(.down, false);
    try testing.expectEqual(@as(usize, 16 + 8), b.caret); // column 8 again
    b.move(.down, false);
    try testing.expectEqual(b.len, b.caret); // last line: to the end
    b.move(.doc_start, false);
    b.move(.up, false);
    try testing.expectEqual(@as(usize, 0), b.caret);
    try testing.expectEqual(@as(usize, 4), b.lineCount());
    try testing.expectEqual(@as(usize, 3), b.lineOf(b.len));
    try testing.expectEqual(@as(usize, 15), b.startOfLine(2));
    try testing.expectEqual(b.len, b.startOfLine(99));
}

test "tabs advance to the next stop and map back to positions" {
    var store: [32]u8 = undefined;
    var b = make(&store, "\tx\ty");
    try testing.expectEqual(@as(usize, 4), b.column(1));
    try testing.expectEqual(@as(usize, 5), b.column(2));
    try testing.expectEqual(@as(usize, 8), b.column(3));
    try testing.expectEqual(@as(usize, 0), b.atColumn(0, 1)); // nearer the tab's start
    try testing.expectEqual(@as(usize, 1), b.atColumn(0, 3)); // nearer its end
    try testing.expectEqual(@as(usize, 4), b.atColumn(0, 99));
}

test "only plain text is editable, and CR LF becomes LF" {
    try testing.expect(problemWith("plain\ttext\nok\r\n") == null);
    try testing.expect(problemWith("nul\x00byte") != null);
    try testing.expect(problemWith("caf\xc3\xa9") != null);
    var crlf = "a\r\nb\rc\n".*;
    const n = normalizeNewlines(&crlf);
    try testing.expectEqualStrings("a\nb\nc\n", crlf[0..n]);
}
