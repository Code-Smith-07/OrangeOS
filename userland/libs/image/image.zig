//! Image decoding for Quick Look and Image Viewer (docs/design/014, M3 and
//! M4): PNG, BMP and PPM into 0x00RRGGBB pixels, with transparency blended
//! over a background colour.
//!
//! Files come from anywhere, so nothing in them is trusted: sizes are
//! bounded before any memory is taken, every read is checked against the
//! data's length, and a damaged file is an error, never a crash.
//!
//! PNG: 8-bit and 16-bit grey, RGB, palette, grey+alpha and RGBA; 1, 2 and
//! 4-bit grey and palette; all five row filters. Interlaced (Adam7) files
//! are reported as unsupported rather than drawn wrongly.
const std = @import("std");

pub const Error = error{ Unsupported, Corrupt, TooLarge, OutOfMemory };

pub const MAX_SIDE: u32 = 8192;
pub const MAX_PIXELS: u64 = 16 * 1024 * 1024;

pub const Format = enum { png, bmp, ppm };

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    format: Format,
};

pub const Info = struct { width: u32, height: u32, format: Format };

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}
fn le16(b: []const u8) u32 {
    return std.mem.readInt(u16, b[0..2], .little);
}

fn checkSize(w: u32, h: u32) Error!void {
    if (w == 0 or h == 0) return Error.Corrupt;
    if (w > MAX_SIDE or h > MAX_SIDE or @as(u64, w) * h > MAX_PIXELS) return Error.TooLarge;
}

const PNG_MAGIC = "\x89PNG\r\n\x1a\n";

/// The size and format, read from the header alone.
pub fn probe(bytes: []const u8) Error!Info {
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], PNG_MAGIC)) {
        if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return Error.Corrupt;
        const info = Info{ .width = be32(bytes[16..]), .height = be32(bytes[20..]), .format = .png };
        try checkSize(info.width, info.height);
        return info;
    }
    if (bytes.len >= 26 and bytes[0] == 'B' and bytes[1] == 'M') {
        const w: i32 = @bitCast(le32(bytes[18..]));
        const h: i32 = @bitCast(le32(bytes[22..]));
        if (w <= 0 or h == 0 or h == std.math.minInt(i32)) return Error.Corrupt;
        const info = Info{ .width = @intCast(w), .height = @abs(h), .format = .bmp };
        try checkSize(info.width, info.height);
        return info;
    }
    if (bytes.len >= 2 and bytes[0] == 'P' and bytes[1] == '6') {
        var p = PpmHeader{ .bytes = bytes, .at = 2 };
        const w = try p.number();
        const h = try p.number();
        try checkSize(w, h);
        return .{ .width = w, .height = h, .format = .ppm };
    }
    return Error.Unsupported;
}

/// How much memory decode() needs from its allocator for this image.
pub fn memoryNeeded(bytes: []const u8) Error!usize {
    const info = try probe(bytes);
    const pixels: usize = @as(usize, info.width) * info.height * 4;
    if (info.format != .png) return pixels + 4096;
    // Worst case 8 bytes a pixel plus a filter byte a row, and the
    // compressed data gathered from the IDAT chunks.
    const raw: usize = @as(usize, info.height) * (@as(usize, info.width) * 8 + 1);
    return pixels + raw + bytes.len + 64 * 1024;
}

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator, background: u32) Error!Image {
    const info = try probe(bytes);
    const pixels = allocator.alloc(u32, @as(usize, info.width) * info.height) catch return Error.OutOfMemory;
    errdefer allocator.free(pixels);
    switch (info.format) {
        .png => try decodePng(bytes, allocator, info, pixels, background),
        .bmp => try decodeBmp(bytes, info, pixels, background),
        .ppm => try decodePpm(bytes, info, pixels),
    }
    return .{ .width = info.width, .height = info.height, .pixels = pixels, .format = info.format };
}

fn over(bg: u32, r: u32, g: u32, b: u32, a: u32) u32 {
    if (a >= 255) return (r << 16) | (g << 8) | b;
    const inv = 255 - a;
    const rr = (r * a + ((bg >> 16) & 255) * inv + 127) / 255;
    const gg = (g * a + ((bg >> 8) & 255) * inv + 127) / 255;
    const bb = (b * a + (bg & 255) * inv + 127) / 255;
    return (rr << 16) | (gg << 8) | bb;
}

// ── PPM ───────────────────────────────────────────────────────────────────

const PpmHeader = struct {
    bytes: []const u8,
    at: usize,

    fn number(self: *PpmHeader) Error!u32 {
        // Whitespace and # comments separate the header's numbers.
        while (self.at < self.bytes.len) {
            const c = self.bytes[self.at];
            if (c == '#') {
                while (self.at < self.bytes.len and self.bytes[self.at] != '\n') self.at += 1;
            } else if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                self.at += 1;
            } else break;
        }
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.at < self.bytes.len and self.bytes[self.at] >= '0' and self.bytes[self.at] <= '9') : (self.at += 1) {
            if (digits == 9) return Error.Corrupt;
            value = value * 10 + (self.bytes[self.at] - '0');
            digits += 1;
        }
        if (digits == 0) return Error.Corrupt;
        return value;
    }
};

fn decodePpm(bytes: []const u8, info: Info, out: []u32) Error!void {
    var p = PpmHeader{ .bytes = bytes, .at = 2 };
    _ = try p.number();
    _ = try p.number();
    const max = try p.number();
    if (max != 255) return Error.Unsupported;
    // Exactly one whitespace byte, then the samples.
    if (p.at >= bytes.len) return Error.Corrupt;
    const data = bytes[p.at + 1 ..];
    const count = @as(usize, info.width) * info.height;
    if (data.len < count * 3) return Error.Corrupt;
    for (out, 0..) |*px, i| px.* = (@as(u32, data[i * 3]) << 16) | (@as(u32, data[i * 3 + 1]) << 8) | data[i * 3 + 2];
}

// ── BMP ───────────────────────────────────────────────────────────────────

fn decodeBmp(bytes: []const u8, info: Info, out: []u32, background: u32) Error!void {
    if (bytes.len < 54) return Error.Corrupt;
    const offset: usize = le32(bytes[10..]);
    const header = le32(bytes[14..]);
    if (header < 40) return Error.Unsupported;
    const top_down = @as(i32, @bitCast(le32(bytes[22..]))) < 0;
    const bpp = le16(bytes[28..]);
    const compression = le32(bytes[30..]);
    if (bpp != 24 and bpp != 32) return Error.Unsupported;
    if (compression != 0 and !(compression == 3 and bpp == 32)) return Error.Unsupported;
    const row: usize = ((@as(usize, info.width) * bpp + 31) / 32) * 4;
    if (offset > bytes.len or (bytes.len - offset) / row < info.height) return Error.Corrupt;
    // 32-bit files only carry real alpha when a pixel says so; many leave
    // the byte zero, which must not make the whole picture invisible.
    var has_alpha = false;
    if (bpp == 32) {
        var i: usize = offset + 3;
        while (i < offset + row * info.height) : (i += 4) if (bytes[i] != 0) {
            has_alpha = true;
            break;
        };
    }
    for (0..info.height) |y| {
        const src = bytes[offset + (if (top_down) y else info.height - 1 - y) * row ..];
        for (0..info.width) |x| {
            const p = src[x * (bpp / 8) ..];
            const a: u32 = if (has_alpha) p[3] else 255;
            out[y * info.width + x] = over(background, p[2], p[1], p[0], a);
        }
    }
}

// ── PNG ───────────────────────────────────────────────────────────────────

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn decodePng(bytes: []const u8, allocator: std.mem.Allocator, info: Info, out: []u32, background: u32) Error!void {
    if (bytes.len < 33) return Error.Corrupt;
    const depth = bytes[24];
    const color = bytes[25];
    if (bytes[26] != 0 or bytes[27] != 0) return Error.Corrupt;
    if (bytes[28] != 0) return Error.Unsupported; // Adam7 interlace
    const channels: usize = switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return Error.Corrupt,
    };
    const depth_ok = switch (color) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => depth == 8 or depth == 16,
    };
    if (!depth_ok) return Error.Corrupt;
    const bits = channels * depth;
    const stride: usize = (@as(usize, info.width) * bits + 7) / 8;
    const bpp: usize = @max(1, bits / 8);

    // Walk the chunks: palette, transparency, and all image data.
    var palette: [256]u32 = [_]u32{0} ** 256;
    var palette_alpha: [256]u8 = [_]u8{255} ** 256;
    var palette_len: usize = 0;
    var key: ?[3]u16 = null;
    const compressed = allocator.alloc(u8, bytes.len) catch return Error.OutOfMemory;
    defer allocator.free(compressed);
    var compressed_len: usize = 0;
    var at: usize = 8;
    var ended = false;
    while (at + 12 <= bytes.len) {
        const len: usize = be32(bytes[at..]);
        const kind = bytes[at + 4 .. at + 8];
        if (len > bytes.len - at - 12) return Error.Corrupt;
        const data = bytes[at + 8 .. at + 8 + len];
        if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len > 768) return Error.Corrupt;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = (@as(u32, data[i * 3]) << 16) | (@as(u32, data[i * 3 + 1]) << 8) | data[i * 3 + 2];
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (color == 3) {
                for (data[0..@min(len, 256)], 0..) |a, i| palette_alpha[i] = a;
            } else if (color == 0 and len >= 2) {
                const v = std.mem.readInt(u16, data[0..2], .big);
                key = .{ v, v, v };
            } else if (color == 2 and len >= 6) {
                key = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            @memcpy(compressed[compressed_len..][0..len], data);
            compressed_len += len;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            ended = true;
            break;
        }
        at += 12 + len;
    }
    if (!ended or compressed_len == 0) return Error.Corrupt;
    if (color == 3 and palette_len == 0) return Error.Corrupt;

    const raw_len = @as(usize, info.height) * (stride + 1);
    const raw = allocator.alloc(u8, raw_len) catch return Error.OutOfMemory;
    defer allocator.free(raw);
    var stream = std.io.fixedBufferStream(compressed[0..compressed_len]);
    var inflate = std.compress.zlib.decompressor(stream.reader());
    const got = inflate.reader().readAll(raw) catch return Error.Corrupt;
    if (got != raw_len) return Error.Corrupt;

    // Undo the row filters in place; `prev` is the row above (zeros at first).
    for (0..info.height) |y| {
        const line = raw[y * (stride + 1) ..][0 .. stride + 1];
        const filter = line[0];
        const cur = line[1..];
        const prev: ?[]const u8 = if (y == 0) null else raw[(y - 1) * (stride + 1) + 1 ..][0..stride];
        for (cur, 0..) |*v, i| {
            const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            v.* +%= switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @intCast((@as(u16, a) + b) / 2),
                4 => paeth(a, b, c),
                else => return Error.Corrupt,
            };
        }
        const dst = out[y * info.width ..][0..info.width];
        for (dst, 0..) |*px, x| {
            if (depth < 8) {
                // Packed samples, most significant bits first.
                const bit = x * depth;
                const shift: u3 = @intCast(8 - depth - (bit % 8));
                const v: u32 = (cur[bit / 8] >> shift) & ((@as(u8, 1) << @intCast(depth)) - 1);
                if (color == 3) {
                    if (v >= palette_len) return Error.Corrupt;
                    const rgb = palette[v];
                    px.* = over(background, rgb >> 16, (rgb >> 8) & 255, rgb & 255, palette_alpha[v]);
                } else {
                    const grey = v * 255 / ((@as(u32, 1) << @intCast(depth)) - 1);
                    const transparent = if (key) |k| k[0] == v else false;
                    px.* = over(background, grey, grey, grey, if (transparent) 0 else 255);
                }
                continue;
            }
            const step = depth / 8;
            const p = cur[x * channels * step ..];
            // 16-bit samples: the high byte is the 8-bit value.
            const s = [4]u32{ p[0], if (channels > 1) p[step] else 0, if (channels > 2) p[2 * step] else 0, if (channels > 3) p[3 * step] else 0 };
            switch (color) {
                0 => {
                    const full: u16 = if (step == 2) std.mem.readInt(u16, p[0..2], .big) else p[0];
                    const transparent = if (key) |k| k[0] == full else false;
                    px.* = over(background, s[0], s[0], s[0], if (transparent) 0 else 255);
                },
                2 => {
                    var transparent = false;
                    if (key) |k| {
                        const r: u16 = if (step == 2) std.mem.readInt(u16, p[0..2], .big) else p[0];
                        const g: u16 = if (step == 2) std.mem.readInt(u16, p[2..4], .big) else p[1];
                        const b: u16 = if (step == 2) std.mem.readInt(u16, p[4..6], .big) else p[2];
                        transparent = r == k[0] and g == k[1] and b == k[2];
                    }
                    px.* = over(background, s[0], s[1], s[2], if (transparent) 0 else 255);
                },
                3 => {
                    if (s[0] >= palette_len) return Error.Corrupt;
                    const rgb = palette[s[0]];
                    px.* = over(background, rgb >> 16, (rgb >> 8) & 255, rgb & 255, palette_alpha[s[0]]);
                },
                4 => px.* = over(background, s[0], s[0], s[0], s[1]),
                else => px.* = over(background, s[0], s[1], s[2], s[3]),
            }
        }
    }
}

/// The colour at (x, y) in 24.8 fixed point, blended from the four
/// nearest pixels: for drawing an image at any size.
pub fn sample(img: *const Image, fx: i64, fy: i64) u32 {
    const max_x: i64 = @as(i64, img.width) - 1;
    const max_y: i64 = @as(i64, img.height) - 1;
    const x = std.math.clamp(fx, 0, max_x << 8);
    const y = std.math.clamp(fy, 0, max_y << 8);
    const x0: usize = @intCast(x >> 8);
    const y0: usize = @intCast(y >> 8);
    const x1: usize = @intCast(@min(max_x, (x >> 8) + 1));
    const y1: usize = @intCast(@min(max_y, (y >> 8) + 1));
    const tx: u32 = @intCast(x & 255);
    const ty: u32 = @intCast(y & 255);
    const w = img.width;
    const a = img.pixels[y0 * w + x0];
    const b = img.pixels[y0 * w + x1];
    const c = img.pixels[y1 * w + x0];
    const d = img.pixels[y1 * w + x1];
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const top = ((a >> shift) & 255) * (256 - tx) + ((b >> shift) & 255) * tx;
        const bottom = ((c >> shift) & 255) * (256 - tx) + ((d >> shift) & 255) * tx;
        out |= ((top * (256 - ty) + bottom * ty + 32768) >> 16) << shift;
    }
    return out;
}

/// The largest size that fits `box_w` x `box_h` without changing the
/// picture's shape; never larger than `max_scale_percent` of its own size.
pub fn fit(width: u32, height: u32, box_w: i32, box_h: i32, max_scale_percent: u32) [2]i32 {
    const bw: u64 = @intCast(@max(1, box_w));
    const bh: u64 = @intCast(@max(1, box_h));
    var w: u64 = bw;
    var h: u64 = @max(1, @as(u64, height) * bw / width);
    if (h > bh) {
        h = bh;
        w = @max(1, @as(u64, width) * bh / height);
    }
    const limit_w = @as(u64, width) * max_scale_percent / 100;
    if (w > limit_w and limit_w > 0) {
        w = limit_w;
        h = @max(1, @as(u64, height) * max_scale_percent / 100);
    }
    return .{ @intCast(w), @intCast(h) };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const png_rgb_filters = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 4, 0, 0, 0, 5, 8, 2, 0, 0, 0, 237, 207, 218, 140, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 96, 96, 56, 97, 165, 61, 166, 170, 0, 0, 0, 42, 73, 68, 65, 84, 35, 178, 170, 66, 163, 103, 139, 77, 30, 35, 151, 209, 65, 27, 145, 71, 16, 196, 196, 101, 244, 19, 142, 152, 69, 82, 194, 148, 149, 223, 65, 16, 11, 72, 76, 4, 138, 0, 202, 15, 22, 162, 90, 104, 171, 45, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const png_rgba = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 6, 0, 0, 0, 114, 182, 13, 36, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 248, 207, 192, 240, 84, 128, 189, 219, 0, 0, 0, 15, 73, 68, 65, 84, 31, 8, 27, 24, 64, 52, 151, 136, 220, 127, 0, 55, 128, 5, 184, 127, 238, 189, 68, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const png_palette = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 3, 0, 0, 0, 1, 8, 3, 0, 0, 0, 44, 62, 228, 134, 0, 0, 0, 9, 80, 76, 84, 69, 255, 0, 0, 0, 255, 0, 0, 0, 255, 45, 74, 205, 138, 0, 0, 0, 2, 116, 82, 78, 83, 255, 0, 229, 183, 48, 74, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 96, 96, 100, 2, 103, 136, 132, 16, 0, 0, 0, 5, 73, 68, 65, 84, 0, 0, 8, 0, 4, 69, 242, 204, 104, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const png_gray2 = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 4, 0, 0, 0, 1, 2, 0, 0, 0, 0, 150, 231, 72, 176, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 144, 6, 0, 0, 66, 43, 234, 170, 0, 0, 0, 3, 73, 68, 65, 84, 29, 0, 28, 249, 53, 34, 206, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const png_gray_alpha = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0, 0, 0, 181, 28, 12, 2, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 56, 241, 31, 0, 183, 37, 176, 139, 0, 0, 0, 4, 73, 68, 65, 84, 2, 146, 1, 200, 50, 25, 56, 209, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };
const png_interlaced = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 1, 144, 119, 83, 222, 0, 0, 0, 7, 73, 68, 65, 84, 120, 218, 99, 96, 100, 98, 6, 49, 182, 79, 83, 0, 0, 0, 5, 73, 68, 65, 84, 0, 0, 14, 0, 7, 216, 118, 225, 96, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130 };

test "PNG: every row filter decodes to the original pixels" {
    const img = try decode(&png_rgb_filters, testing.allocator, 0xFFFFFF);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqual(@as(u32, 4), img.width);
    try testing.expectEqual(@as(u32, 5), img.height);
    for (0..5) |y| for (0..4) |x| {
        const r: u32 = @intCast((x * 60 + y * 10) & 255);
        const g: u32 = @intCast((x * 20 + y * 50) & 255);
        const b: u32 = @intCast((200 - x * 30 - y * 7) & 255);
        try testing.expectEqual((r << 16) | (g << 8) | b, img.pixels[y * 4 + x]);
    };
}

test "PNG: alpha, palettes with transparency and packed greys" {
    const rgba = try decode(&png_rgba, testing.allocator, 0xFFFFFF);
    defer testing.allocator.free(rgba.pixels);
    try testing.expectEqual(@as(u32, 0xFF0000), rgba.pixels[0]);
    try testing.expectEqual(@as(u32, 0x7FFF7F), rgba.pixels[1]); // half green over white
    try testing.expectEqual(@as(u32, 0xFFFFFF), rgba.pixels[2]); // fully transparent
    try testing.expectEqual(@as(u32, 0x0A141E), rgba.pixels[3]);
    const pal = try decode(&png_palette, testing.allocator, 0x000000);
    defer testing.allocator.free(pal.pixels);
    try testing.expectEqualSlices(u32, &.{ 0xFF0000, 0x000000, 0x0000FF }, pal.pixels);
    const grey = try decode(&png_gray2, testing.allocator, 0);
    defer testing.allocator.free(grey.pixels);
    try testing.expectEqualSlices(u32, &.{ 0x000000, 0x555555, 0xAAAAAA, 0xFFFFFF }, grey.pixels);
    const ga = try decode(&png_gray_alpha, testing.allocator, 0);
    defer testing.allocator.free(ga.pixels);
    try testing.expectEqual(@as(u32, 0xC8C8C8), ga.pixels[0]);
}

test "PNG: interlaced, cut short and damaged files are errors, not crashes" {
    try testing.expectError(Error.Unsupported, decode(&png_interlaced, testing.allocator, 0));
    // Every truncation of a good file fails cleanly.
    for (0..png_rgb_filters.len) |n| {
        if (decode(png_rgb_filters[0..n], testing.allocator, 0)) |img| {
            testing.allocator.free(img.pixels);
            return error.TruncatedFileDecoded;
        } else |_| {}
    }
    // Flipping bytes of the compressed data must never crash or leak.
    var copy = png_rgb_filters;
    for (41..copy.len - 12) |i| {
        copy[i] ^= 0x5A;
        if (decode(&copy, testing.allocator, 0)) |img| testing.allocator.free(img.pixels) else |_| {}
        copy[i] ^= 0x5A;
    }
    // A header claiming a huge picture is refused before any allocation.
    var huge = png_rgba;
    std.mem.writeInt(u32, huge[16..20], 60000, .big);
    try testing.expectError(Error.TooLarge, probe(&huge));
    try testing.expectError(Error.Unsupported, probe("GIF89a not supported here"));
}

test "BMP: bottom-up 24-bit, top-down 32-bit, and files cut short" {
    // 2x2, 24-bit, bottom-up: rows are stored last first, padded to 4 bytes.
    var bmp = [_]u8{0} ** (54 + 16);
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(u32, bmp[10..14], 54, .little);
    std.mem.writeInt(u32, bmp[14..18], 40, .little);
    std.mem.writeInt(u32, bmp[18..22], 2, .little);
    std.mem.writeInt(u32, bmp[22..26], 2, .little);
    std.mem.writeInt(u16, bmp[28..30], 24, .little);
    const rows = [_]u8{ 3, 2, 1, 6, 5, 4, 0, 0, 9, 8, 7, 12, 11, 10, 0, 0 };
    @memcpy(bmp[54..], &rows);
    const img = try decode(&bmp, testing.allocator, 0);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqualSlices(u32, &.{ 0x070809, 0x0A0B0C, 0x010203, 0x040506 }, img.pixels);
    try testing.expectError(Error.Corrupt, decode(bmp[0..60], testing.allocator, 0));
    // The same file marked top-down keeps the stored order.
    std.mem.writeInt(i32, bmp[22..26], -2, .little);
    const flipped = try decode(&bmp, testing.allocator, 0);
    defer testing.allocator.free(flipped.pixels);
    try testing.expectEqual(@as(u32, 0x010203), flipped.pixels[0]);
}

test "PPM: comments in the header, and a short body is refused" {
    const ppm = "P6\n# made by a test\n2 1\n255\n" ++ "\x01\x02\x03\x0A\x0B\x0C";
    const img = try decode(ppm, testing.allocator, 0);
    defer testing.allocator.free(img.pixels);
    try testing.expectEqualSlices(u32, &.{ 0x010203, 0x0A0B0C }, img.pixels);
    try testing.expectError(Error.Corrupt, decode(ppm[0 .. ppm.len - 1], testing.allocator, 0));
    try testing.expectError(Error.Unsupported, decode("P6 1 1 65535\n\x00\x00\x00\x00\x00\x00", testing.allocator, 0));
}

test "fitting keeps the shape and sampling blends neighbours" {
    try testing.expectEqual([2]i32{ 400, 200 }, fit(800, 400, 400, 400, 100));
    try testing.expectEqual([2]i32{ 100, 200 }, fit(400, 800, 400, 200, 100));
    // Small pictures are not blown up past the limit.
    try testing.expectEqual([2]i32{ 20, 10 }, fit(20, 10, 400, 400, 100));
    try testing.expectEqual([2]i32{ 40, 20 }, fit(20, 10, 400, 400, 200));
    var px = [_]u32{ 0x000000, 0xFFFFFF };
    const img = Image{ .width = 2, .height = 1, .pixels = &px, .format = .ppm };
    try testing.expectEqual(@as(u32, 0x000000), sample(&img, 0, 0));
    try testing.expectEqual(@as(u32, 0x808080), sample(&img, 128, 0));
    try testing.expectEqual(@as(u32, 0xFFFFFF), sample(&img, 9999, 9999));
}
