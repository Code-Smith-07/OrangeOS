//! Minimal allocation-free formatting for kernel output.
//!
//! Supports a small subset of Zig's format syntax, enough for boot diagnostics:
//!   {s}  string            {d}  decimal          {x}  lowercase hex
//!   {X}  uppercase hex     {c}  character        {b}  binary
//!   {}   auto (int → decimal, string → string, bool → true/false)
//!
//! Width padding uses `{d:>8}` / `{x:0>16}` style: fill char, '>' , width.

const std = @import("std");

pub const Error = error{NoSpace};

pub const Buffer = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn init(bytes: []u8) Buffer {
        return .{ .bytes = bytes };
    }

    pub fn write(self: *Buffer, s: []const u8) void {
        for (s) |c| self.writeByte(c);
    }

    pub fn writeByte(self: *Buffer, c: u8) void {
        if (self.len >= self.bytes.len) return; // silently truncate
        self.bytes[self.len] = c;
        self.len += 1;
    }

    pub fn slice(self: *const Buffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn writeUnsigned(buf: *Buffer, value: u64, base: u8, upper: bool, width: usize, fill: u8) void {
    var digits: [64]u8 = undefined;
    var n: usize = 0;
    var v = value;

    if (v == 0) {
        digits[0] = '0';
        n = 1;
    } else {
        while (v != 0) : (v /= base) {
            const d: u8 = @intCast(v % base);
            digits[n] = if (d < 10)
                '0' + d
            else if (upper)
                'A' + (d - 10)
            else
                'a' + (d - 10);
            n += 1;
        }
    }

    var pad = if (width > n) width - n else 0;
    while (pad > 0) : (pad -= 1) buf.writeByte(fill);

    while (n > 0) {
        n -= 1;
        buf.writeByte(digits[n]);
    }
}

fn writeSigned(buf: *Buffer, value: i64, width: usize, fill: u8) void {
    if (value < 0) {
        buf.writeByte('-');
        const mag: u64 = @intCast(-(value + 1));
        writeUnsigned(buf, mag + 1, 10, false, width, fill);
    } else {
        writeUnsigned(buf, @intCast(value), 10, false, width, fill);
    }
}

/// Parses `0>16` style specs into (fill, width).
fn parsePad(comptime spec: []const u8) struct { fill: u8, width: usize } {
    if (spec.len == 0) return .{ .fill = ' ', .width = 0 };
    comptime var i: usize = 0;
    comptime var fill: u8 = ' ';
    if (spec.len >= 2 and spec[1] == '>') {
        fill = spec[0];
        i = 2;
    } else if (spec[0] == '>') {
        i = 1;
    }
    comptime var width: usize = 0;
    inline while (i < spec.len) : (i += 1) {
        width = width * 10 + (spec[i] - '0');
    }
    return .{ .fill = fill, .width = width };
}

/// Accepts both slices (`[]const u8`) and C-style sentinel pointers
/// (`[*:0]const u8`), which is what the Limine response strings are.
fn writeStringLike(buf: *Buffer, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => buf.write(value),
            .many, .c => {
                var i: usize = 0;
                while (value[i] != 0) : (i += 1) buf.writeByte(value[i]);
            },
            .one => buf.write(value),
        },
        else => buf.write("<?>"),
    }
}

fn formatValue(buf: *Buffer, value: anytype, comptime verb: u8, comptime spec: []const u8) void {
    const pad = comptime parsePad(spec);
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (verb) {
        's' => writeStringLike(buf, value),
        'c' => buf.writeByte(@intCast(value)),
        'd' => switch (info) {
            .int => |i| if (i.signedness == .signed)
                writeSigned(buf, @intCast(value), pad.width, pad.fill)
            else
                writeUnsigned(buf, @intCast(value), 10, false, pad.width, pad.fill),
            .comptime_int => writeSigned(buf, value, pad.width, pad.fill),
            else => buf.write("<?>"),
        },
        'x' => writeUnsigned(buf, @intCast(value), 16, false, pad.width, pad.fill),
        'X' => writeUnsigned(buf, @intCast(value), 16, true, pad.width, pad.fill),
        'b' => writeUnsigned(buf, @intCast(value), 2, false, pad.width, pad.fill),
        else => switch (info) {
            .pointer => writeStringLike(buf, value),
            .bool => buf.write(if (value) "true" else "false"),
            .int, .comptime_int => writeSigned(buf, @intCast(value), pad.width, pad.fill),
            else => buf.write("<?>"),
        },
    }
}

/// Format into `out`, returning the written slice. Output is truncated rather
/// than erroring — a kernel log line is never worth a failed boot.
pub fn bufPrint(out: []u8, comptime format: []const u8, args: anytype) []const u8 {
    var buf = Buffer.init(out);
    comptime var arg_index: usize = 0;
    comptime var i: usize = 0;

    inline while (i < format.len) {
        if (format[i] == '{') {
            if (i + 1 < format.len and format[i + 1] == '{') {
                buf.writeByte('{');
                i += 2;
                continue;
            }
            // Find the closing brace.
            comptime var j = i + 1;
            inline while (j < format.len and format[j] != '}') : (j += 1) {}
            const inner = format[i + 1 .. j];

            // Split "verb:spec".
            comptime var verb: u8 = 0;
            comptime var spec: []const u8 = "";
            comptime {
                if (inner.len > 0) {
                    var colon: ?usize = null;
                    for (inner, 0..) |c, k| {
                        if (c == ':') {
                            colon = k;
                            break;
                        }
                    }
                    if (colon) |ci| {
                        if (ci > 0) verb = inner[0];
                        spec = inner[ci + 1 ..];
                    } else {
                        verb = inner[0];
                    }
                }
            }

            formatValue(&buf, args[arg_index], verb, spec);
            arg_index += 1;
            i = j + 1;
        } else if (format[i] == '}') {
            if (i + 1 < format.len and format[i + 1] == '}') {
                buf.writeByte('}');
                i += 2;
                continue;
            }
            buf.writeByte('}');
            i += 1;
        } else {
            buf.writeByte(format[i]);
            i += 1;
        }
    }

    return buf.slice();
}

/// Human-readable byte counts: 1536 → "1.5 KiB".
pub fn humanBytes(out: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var v = bytes;
    var frac: u64 = 0;
    var unit: usize = 0;
    while (v >= 1024 and unit + 1 < units.len) : (unit += 1) {
        frac = ((v % 1024) * 10) / 1024;
        v /= 1024;
    }
    if (unit == 0) return bufPrint(out, "{d} B", .{v});
    return bufPrint(out, "{d}.{d} {s}", .{ v, frac, units[unit] });
}
