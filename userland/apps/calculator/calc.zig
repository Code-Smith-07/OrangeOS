//! The Calculator's arithmetic (docs/design/014, M4): an ordinary pocket
//! calculator. Each operation is worked out as soon as the next one is
//! pressed (2 + 3 x 4 = gives 20), = repeats the last operation, % turns
//! the entry into a percentage of what came before, and dividing by zero
//! shows an error until Clear. No drawing here, so every key is tested.
const std = @import("std");

pub const MAX_DIGITS = 12;

pub const Calc = struct {
    /// What is being typed, as text.
    entry: [MAX_DIGITS + 2]u8 = undefined,
    entry_len: usize = 0,
    /// The value shown when nothing is being typed.
    value: f64 = 0,
    accumulator: f64 = 0,
    pending: ?u8 = null,
    /// For repeating = : the last operation and its right-hand side.
    repeat_op: ?u8 = null,
    repeat_value: f64 = 0,
    typing: bool = false,
    failed: bool = false,

    fn entryValue(self: *const Calc) f64 {
        if (!self.typing) return self.value;
        return std.fmt.parseFloat(f64, self.entry[0..self.entry_len]) catch 0;
    }

    fn apply(op: u8, a: f64, b: f64) ?f64 {
        const r = switch (op) {
            '+' => a + b,
            '-' => a - b,
            '*' => a * b,
            '/' => if (b == 0) return null else a / b,
            else => return null,
        };
        return if (std.math.isFinite(r)) r else null;
    }

    fn fail(self: *Calc) void {
        self.* = .{ .failed = true };
    }

    /// Press a key: 0-9 . + - * / = and C (clear), S (sign), % and B
    /// (backspace). Anything else is ignored. True when the display changed.
    pub fn press(self: *Calc, key: u8) bool {
        if (self.failed) {
            if (key != 'C' and !(key >= '0' and key <= '9') and key != '.') return false;
            self.* = .{};
            if (key == 'C') return true;
        }
        switch (key) {
            '0'...'9', '.' => {
                if (!self.typing) {
                    self.entry_len = 0;
                    self.typing = true;
                }
                const text = self.entry[0..self.entry_len];
                if (key == '.') {
                    if (std.mem.indexOfScalar(u8, text, '.') != null) return false;
                    if (self.entry_len == 0 or (self.entry_len == 1 and text[0] == '-')) {
                        self.entry[self.entry_len] = '0';
                        self.entry_len += 1;
                    }
                } else {
                    var digits: usize = 0;
                    for (text) |c| digits += @intFromBool(c >= '0' and c <= '9');
                    if (digits >= MAX_DIGITS) return false;
                    // No leading zeros: "0" then "5" is "5".
                    if (std.mem.eql(u8, text, "0")) self.entry_len = 0;
                    if (std.mem.eql(u8, text, "-0")) self.entry_len = 1;
                }
                self.entry[self.entry_len] = key;
                self.entry_len += 1;
            },
            'B' => {
                if (!self.typing or self.entry_len == 0) return false;
                self.entry_len -= 1;
                if (self.entry_len == 0 or (self.entry_len == 1 and self.entry[0] == '-')) {
                    self.entry_len = 0;
                    self.typing = false;
                    self.value = 0;
                }
            },
            '+', '-', '*', '/' => {
                const current = self.entryValue();
                if (self.pending != null and self.typing) {
                    self.accumulator = apply(self.pending.?, self.accumulator, current) orelse {
                        self.fail();
                        return true;
                    };
                } else self.accumulator = current;
                self.pending = key;
                self.repeat_op = null;
                self.value = self.accumulator;
                self.typing = false;
            },
            '=' => {
                var op: u8 = undefined;
                var right: f64 = undefined;
                if (self.pending) |p| {
                    op = p;
                    right = self.entryValue();
                } else if (self.repeat_op) |r| {
                    op = r;
                    right = self.repeat_value;
                    self.accumulator = self.entryValue();
                } else {
                    self.value = self.entryValue();
                    self.typing = false;
                    return true;
                }
                self.accumulator = apply(op, self.accumulator, right) orelse {
                    self.fail();
                    return true;
                };
                self.repeat_op = op;
                self.repeat_value = right;
                self.pending = null;
                self.value = self.accumulator;
                self.typing = false;
            },
            '%' => {
                const current = self.entryValue();
                // 200 + 10 % means 10 percent of 200.
                self.value = if (self.pending != null) self.accumulator * current / 100 else current / 100;
                self.typing = false;
                if (self.pending != null) {
                    // The percentage is the right-hand side of the pending sum.
                    var buf: [32]u8 = undefined;
                    const text = format(self.value, &buf);
                    if (text.len <= self.entry.len) {
                        @memcpy(self.entry[0..text.len], text);
                        self.entry_len = text.len;
                        self.typing = true;
                    }
                }
            },
            'S' => {
                if (self.typing) {
                    if (self.entry_len > 0 and self.entry[0] == '-') {
                        std.mem.copyForwards(u8, self.entry[0 .. self.entry_len - 1], self.entry[1..self.entry_len]);
                        self.entry_len -= 1;
                    } else if (self.entry_len < self.entry.len) {
                        std.mem.copyBackwards(u8, self.entry[1 .. self.entry_len + 1], self.entry[0..self.entry_len]);
                        self.entry[0] = '-';
                        self.entry_len += 1;
                    }
                } else self.value = -self.value;
            },
            'C' => self.* = .{},
            else => return false,
        }
        return true;
    }

    /// What the display shows.
    pub fn display(self: *const Calc, buf: []u8) []const u8 {
        if (self.failed) return "Not a number";
        if (self.typing) return self.entry[0..self.entry_len];
        return format(self.value, buf);
    }

    /// The operation waiting for its right-hand side, for the display.
    pub fn pendingSymbol(self: *const Calc) ?u8 {
        return self.pending;
    }
};

/// A number as a calculator shows it: up to ten significant digits, no
/// trailing zeros, and powers of ten only when the number is too large or
/// too small to write out.
pub fn format(value: f64, buf: []u8) []const u8 {
    if (value == 0) return "0";
    const magnitude = @abs(value);
    if (magnitude >= 1e12 or magnitude < 1e-9) {
        const text = std.fmt.bufPrint(buf, "{e:.6}", .{value}) catch return "?";
        return trimExponent(buf, text);
    }
    // Ten significant digits: the decimals left after the whole part.
    var whole_digits: usize = 1;
    var m = magnitude;
    while (m >= 10) : (m /= 10) whole_digits += 1;
    // Below one, the leading zero is not a significant digit.
    const decimals: usize = if (magnitude < 1) 10 else if (whole_digits >= 10) 0 else 10 - whole_digits;
    const text = std.fmt.bufPrint(buf, "{d:.[1]}", .{ value, decimals }) catch return "?";
    var len = text.len;
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        while (len > 0 and text[len - 1] == '0') len -= 1;
        if (len > 0 and text[len - 1] == '.') len -= 1;
    }
    if (std.mem.eql(u8, text[0..len], "-0")) return "0";
    return text[0..len];
}

/// "1.500000e12" becomes "1.5e12".
fn trimExponent(buf: []u8, text: []const u8) []const u8 {
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse return text;
    var end = e;
    while (end > 0 and text[end - 1] == '0') end -= 1;
    if (end > 0 and text[end - 1] == '.') end -= 1;
    const tail = text[e..];
    std.mem.copyForwards(u8, buf[end .. end + tail.len], tail);
    return buf[0 .. end + tail.len];
}

const testing = std.testing;

fn run(keys: []const u8) Calc {
    var c = Calc{};
    for (keys) |k| _ = c.press(k);
    return c;
}
fn shows(keys: []const u8, expected: []const u8) !void {
    var buf: [32]u8 = undefined;
    const c = run(keys);
    try testing.expectEqualStrings(expected, c.display(&buf));
}

test "sums are worked out as they are typed" {
    try shows("2+3=", "5");
    try shows("2+3*4=", "20");
    try shows("10-4-3=", "3");
    try shows("9/3/3=", "1");
    try shows("7*8", "8");
    try shows("7*8+", "56");
    try shows("1.5+2.25=", "3.75");
    try shows("0.1+0.2=", "0.3");
    try shows("1/3=", "0.3333333333");
    try shows("2*=", "4");
}

test "equals repeats, and typing afterwards starts again" {
    try shows("2+3==", "8");
    try shows("2+3===", "11");
    try shows("5*2=7=", "14");
    try shows("2+3=4", "4");
    try shows("2+3=4+1=", "5");
    try shows("9=", "9");
}

test "entry: decimals, zeros, sign, backspace and the digit limit" {
    try shows("007", "7");
    try shows(".5", "0.5");
    try shows("1.2.3", "1.23");
    try shows("12S", "-12");
    try shows("12SS", "12");
    try shows("5S+3=", "-2");
    try shows("123B", "12");
    try shows("1B", "0");
    try shows("1234567890123456", "123456789012");
    try shows("3+4=S", "-7");
}

test "percent is a share of what came before" {
    try shows("50%", "0.5");
    try shows("200+10%=", "220");
    try shows("200*10%=", "4000");
    try shows("80-25%=", "60");
}

test "dividing by zero is an error until cleared or a new number" {
    try shows("7/0=", "Not a number");
    try shows("7/0=+", "Not a number");
    try shows("7/0=C", "0");
    try shows("7/0=5+1=", "6");
    try shows("1/0+", "Not a number");
    try shows("1/0+2=", "2");
    try shows("999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999*999999999999=", "Not a number");
}

test "numbers are shown the way people write them" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0", format(0, &buf));
    try testing.expectEqualStrings("-0.5", format(-0.5, &buf));
    try testing.expectEqualStrings("1000000", format(1e6, &buf));
    try testing.expectEqualStrings("123456789012", format(123456789012, &buf));
    try testing.expectEqualStrings("1.5e12", format(1.5e12, &buf));
    try testing.expectEqualStrings("2.5e-10", format(2.5e-10, &buf));
    try testing.expectEqualStrings("0.000001", format(1e-6, &buf));
    try testing.expectEqualStrings("3.141592654", format(3.14159265358979, &buf));
    try testing.expectEqualStrings("0", format(-1e-30 * 1e-30 * 0, &buf));
}
