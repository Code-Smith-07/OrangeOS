//! Peel's software renderer.
//!
//! Everything is a CPU store into a 32-bit ARGB buffer. No GPU is involved and
//! A 1280x800 logical desktop at 2x has a 16 MB backing buffer. Damage
//! tracking keeps most updates small; frosted surfaces expand their damage.

pub const Color = u32;

/// Exact backdrop/result cache for a stable frosted surface. Fixed storage;
/// partial clips and oversized surfaces fall back to normal rendering. Compare
/// every source pixel, not a lossy hash: windows/palette changes cannot leave
/// stale glass. Call only after reconstructing the underlying scene.
pub fn FrostCache(comptime capacity: usize) type {
    return struct {
        before: [capacity]u32 = undefined,
        after: [capacity]u32 = undefined,
        valid: bool = false,
        key: Key = undefined,
        hits: usize = 0,
        const Key = struct { rect: Rect, bounds: Rect, scale: i32, radius: i32, tint: Color, opacity: u8, shadow: bool };

        pub fn paint(self: *@This(), s: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8) void {
            self.paintImpl(s, r, radius, tint, opacity, false);
        }

        pub fn paintShadowed(self: *@This(), s: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8) void {
            self.paintImpl(s, r, radius, tint, opacity, true);
        }

        fn render(s: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8, shadow: bool) void {
            if (shadow) {
                var spread: i32 = 8;
                while (spread > 0) : (spread -= 1) {
                    s.rounded(.{ .x = r.x - spread, .y = r.y + 3, .w = r.w + spread * 2, .h = r.h + spread }, radius + spread, 0x333153, 4);
                }
            }
            s.frost(r, radius, tint, opacity);
        }

        fn paintImpl(self: *@This(), s: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8, shadow: bool) void {
            const std = @import("std");
            const extent = if (shadow) shadowExtent(r) else r;
            const bounds = Rect.intersect(extent, .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
            const area = s.clipped(extent);
            if (area.isEmpty()) return;
            const width: usize = @intCast(area.w * s.scale);
            const height: usize = @intCast(area.h * s.scale);
            if (!std.meta.eql(area, bounds) or width * height > capacity) {
                render(s, r, radius, tint, opacity, shadow);
                return;
            }
            const key = Key{ .rect = r, .bounds = bounds, .scale = s.scale, .radius = radius, .tint = tint, .opacity = opacity, .shadow = shadow };
            var matches = self.valid and std.meta.eql(self.key, key);
            for (0..height) |row| {
                const start: usize = @intCast((area.y * s.scale + @as(i32, @intCast(row))) * s.stride + area.x * s.scale);
                const source = s.pixels[start..][0..width];
                const saved = self.before[row * width..][0..width];
                if (matches and !std.mem.eql(u32, source, saved)) matches = false;
                @memcpy(saved, source);
            }
            if (!matches) render(s, r, radius, tint, opacity, shadow);
            for (0..height) |row| {
                const start: usize = @intCast((area.y * s.scale + @as(i32, @intCast(row))) * s.stride + area.x * s.scale);
                const target = s.pixels[start..][0..width];
                const saved = self.after[row * width..][0..width];
                if (matches) @memcpy(target, saved) else @memcpy(saved, target);
            }
            if (matches) self.hits +%= 1;
            self.key = key;
            self.valid = true;
        }
    };
}

pub fn shadowExtent(r: Rect) Rect {
    return .{ .x = r.x - 8, .y = r.y, .w = r.w + 16, .h = r.h + 11 };
}


pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const r = @min(a.right(), b.right());
        const bo = @min(a.bottom(), b.bottom());
        return .{ .x = x, .y = y, .w = r - x, .h = bo - y };
    }

    /// Smallest rectangle covering both. Used to merge damage: several small
    /// dirty regions are cheaper to track as one slightly larger one than to
    /// maintain an exact region list.
    pub fn unionWith(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        const r = @max(a.right(), b.right());
        const bo = @max(a.bottom(), b.bottom());
        return .{ .x = x, .y = y, .w = r - x, .h = bo - y };
    }

    pub fn overlaps(a: Rect, b: Rect) bool {
        return !intersect(a, b).isEmpty();
    }
};

/// Bounded damage set. Distant menu-bar, window and dock updates must not
/// become one screen-sized bounding box. Overflow remains lossless.
pub const Damage = struct {
    rects: [24]Rect = undefined,
    count: usize = 0,
    pub fn add(self: *Damage, rect: Rect) void {
        if (rect.isEmpty()) return;
        var r = rect;
        var i: usize = 0;
        while (i < self.count) {
            if (Rect.overlaps(r, self.rects[i])) {
                r = Rect.unionWith(r, self.rects[i]);
                self.count -= 1;
                self.rects[i] = self.rects[self.count];
                i = 0;
            } else i += 1;
        }
        if (self.count == self.rects.len) {
            for (self.rects[0..self.count]) |old| r = Rect.unionWith(r, old);
            self.count = 0;
        }
        self.rects[self.count] = r;
        self.count += 1;
    }
};

test "damage retains distant rectangles and never loses overflow" {
    const std = @import("std");
    var d: Damage = .{};
    d.add(.{ .x = 0, .y = 0, .w = 100, .h = 10 });
    d.add(.{ .x = 0, .y = 700, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(usize, 2), d.count);
    d.add(.{ .x = 50, .y = 0, .w = 100, .h = 10 });
    try std.testing.expectEqual(@as(usize, 2), d.count);
    for (0..40) |i| d.add(.{ .x = @intCast(i * 10), .y = 400, .w = 2, .h = 2 });
    for (0..40) |i| {
        var covered = false;
        for (d.rects[0..d.count]) |r| covered = covered or r.contains(@intCast(i * 10), 400);
        try std.testing.expect(covered);
    }
}

pub const Surface = struct {
    pixels: [*]u32,
    width: i32,
    height: i32,
    /// Pixels per row, which may exceed width.
    stride: i32,
    /// Physical pixels per logical layout point.
    scale: i32 = 1,

    /// Every draw is clipped to this rectangle. The compositor sets it to the
    /// damage region for the frame, so a partial repaint cannot touch pixels
    /// outside the area it was asked to refresh.
    ///
    /// Without this, any unclipped fill - a window background, say - erases
    /// the whole window while only the damaged sliver gets redrawn on top.
    clip: Rect = .{ .x = 0, .y = 0, .w = 1 << 30, .h = 1 << 30 },

    pub fn setClip(self: *Surface, r: Rect) void {
        self.clip = r;
    }

    pub fn resetClip(self: *Surface) void {
        self.clip = .{ .x = 0, .y = 0, .w = self.width, .h = self.height };
    }

    fn clipped(self: *const Surface, r: Rect) Rect {
        const bounds = Rect{ .x = 0, .y = 0, .w = self.width, .h = self.height };
        return Rect.intersect(Rect.intersect(r, bounds), self.clip);
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }

    pub fn putPhysical(self: *const Surface, x: i32, y: i32, color: Color) void {
        if (x < 0 or y < 0 or x >= self.width * self.scale or y >= self.height * self.scale) return;
        if (!self.clip.contains(@divTrunc(x, self.scale), @divTrunc(y, self.scale))) return;
        self.pixels[@intCast(y * self.stride + x)] = color;
    }
    pub fn getPhysical(self: *const Surface, x: i32, y: i32) Color {
        if (x < 0 or y < 0 or x >= self.width * self.scale or y >= self.height * self.scale) return 0;
        return self.pixels[@intCast(y * self.stride + x)];
    }
    pub inline fn put(self: *const Surface, x: i32, y: i32, c: Color) void {
        self.fill(.{ .x = x, .y = y, .w = 1, .h = 1 }, c);
    }
    pub fn fill(self: *const Surface, r: Rect, c: Color) void {
        const area = self.clipped(r);
        if (area.isEmpty()) return;
        var y = area.y * self.scale;
        while (y < area.bottom() * self.scale) : (y += 1) {
            const begin: usize = @intCast(y * self.stride + area.x * self.scale);
            @memset(self.pixels[begin..][0..@intCast(area.w * self.scale)], c);
        }
    }
    /// Evaluate edges at backing resolution, not in enlarged logical pixels.
    pub fn rounded(self: *const Surface, r: Rect, radius: i32, color: Color, alpha: u8) void {
        const area = self.clipped(r);
        const sc = self.scale;
        const rad = @max(0, @min(radius, @divTrunc(@min(r.w, r.h), 2))) * sc;
        var y = area.y * sc;
        while (y < area.bottom() * sc) : (y += 1) {
            var x = area.x * sc;
            while (x < area.right() * sc) : (x += 1) {
                const dx = @max(@max(r.x * sc + rad - x - 1, x - (r.right() * sc - rad)), 0);
                const dy = @max(@max(r.y * sc + rad - y - 1, y - (r.bottom() * sc - rad)), 0);
                const d = dx * dx + dy * dy;
                if (d > rad * rad) continue;
                var a: u32 = alpha;
                const edge = @max(1, 2 * rad);
                if (rad > 0 and d > rad * rad - edge) a = a * @as(u32, @intCast(rad * rad - d)) / @as(u32, @intCast(edge));
                const idx: usize = @intCast(y * self.stride + x);
                self.pixels[idx] = lerp(self.pixels[idx], color, @intCast(a));
            }
        }
    }

    /// Real backdrop diffusion, followed by a translucent material tint.
    /// The caller must reconstruct the entire clipped-to-screen rectangle
    /// from underlying layers first. Sampling is clamped INSIDE that rectangle
    /// (no hidden halo); never sample last frame's already-composited glass.
    /// Scratch is process-local, bounded and reused by this single-threaded
    /// renderer. Two separable box passes approximate a soft Gaussian.
    pub fn frost(self: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8) void {
        self.frostImpl(r, radius, tint, opacity, false);
    }
    pub fn frostTop(self: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8) void {
        self.frostImpl(r, radius, tint, opacity, true);
    }
    fn frostImpl(self: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8, top_only: bool) void {
        const bounds = Rect.intersect(r, .{ .x = 0, .y = 0, .w = self.width, .h = self.height });
        const area = self.clipped(r);
        if (bounds.isEmpty() or area.isEmpty()) return;
        const step = @max(4, @max(@divTrunc(bounds.w + FROST_W - 1, FROST_W), @divTrunc(bounds.h + FROST_H - 1, FROST_H)));
        const width = @divTrunc(bounds.w + step - 1, step);
        const height = @divTrunc(bounds.h + step - 1, step);
        var y: i32 = 0;
        while (y < height) : (y += 1) {
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                // Four taps average each downsample cell, avoiding single-pixel
                // aliasing when fine text or icons sit behind the glass.
                var red: u32 = 0;
                var green: u32 = 0;
                var blue: u32 = 0;
                for ([_]i32{ 1, 3 }) |dy| for ([_]i32{ 1, 3 }) |dx| {
                    const sx = @min(bounds.right() - 1, bounds.x + x * step + @divTrunc(dx * step, 4));
                    const sy = @min(bounds.bottom() - 1, bounds.y + y * step + @divTrunc(dy * step, 4));
                    const c = self.getPhysical(sx * self.scale, sy * self.scale);
                    red += (c >> 16) & 255;
                    green += (c >> 8) & 255;
                    blue += c & 255;
                };
                frost_a[@intCast(y * width + x)] = ((red / 4) << 16) | ((green / 4) << 8) | (blue / 4);
            }
        }
        for (0..2) |_| {
            blurPass(&frost_a, &frost_b, width, height, true);
            blurPass(&frost_b, &frost_a, width, height, false);
        }
        const sc = self.scale;
        const rad = @max(0, @min(radius, @divTrunc(@min(r.w, r.h), 2))) * sc;
        y = area.y * sc;
        while (y < area.bottom() * sc) : (y += 1) {
            const fy = @max(0, @divTrunc((y - bounds.y * sc) * 256, step * sc) - 128);
            const y0 = @min(height - 1, fy >> 8);
            const y1 = @min(height - 1, y0 + 1);
            var x = area.x * sc;
            while (x < area.right() * sc) : (x += 1) {
                const dx = @max(@max(r.x * sc + rad - x - 1, x - (r.right() * sc - rad)), 0);
                const dy = if (top_only) @max(r.y * sc + rad - y - 1, 0) else @max(@max(r.y * sc + rad - y - 1, y - (r.bottom() * sc - rad)), 0);
                const d = dx * dx + dy * dy;
                if (d > rad * rad) continue;
                const fx = @max(0, @divTrunc((x - bounds.x * sc) * 256, step * sc) - 128);
                const x0 = @min(width - 1, fx >> 8);
                const x1 = @min(width - 1, x0 + 1);
                const top = lerp(frost_a[@intCast(y0 * width + x0)], frost_a[@intCast(y0 * width + x1)], @intCast(fx & 255));
                const bottom = lerp(frost_a[@intCast(y1 * width + x0)], frost_a[@intCast(y1 * width + x1)], @intCast(fx & 255));
                const diffused = lerp(top, bottom, @intCast(fy & 255));
                const material = lerp(diffused, tint, opacity);
                const edge = @max(1, 2 * rad);
                const coverage: u8 = if (rad > 0 and d > rad * rad - edge) @intCast(@divTrunc((rad * rad - d) * 255, edge)) else 255;
                self.putPhysical(x, y, lerp(self.getPhysical(x, y), material, coverage));
            }
        }
    }

    pub fn circle(self: *const Surface, x: i32, y: i32, radius: i32, color: Color) void {
        self.rounded(.{ .x = x - radius, .y = y - radius, .w = radius * 2 + 1, .h = radius * 2 + 1 }, radius, color, 255);
    }

    pub fn line(self: *const Surface, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        var x = x0 * self.scale;
        var y = y0 * self.scale;
        const dx: i32 = @intCast(@abs((x1 - x0) * self.scale));
        const dy: i32 = -@as(i32, @intCast(@abs((y1 - y0) * self.scale)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.putPhysical(x, y, color);
            if (x == x1 * self.scale and y == y1 * self.scale) break;
            const e = 2 * err;
            if (e >= dy) {
                err += dy;
                x += sx;
            }
            if (e <= dx) {
                err += dx;
                y += sy;
            }
        }
    }

    /// Vertical gradient, for the wallpaper.
    pub fn gradient(self: *const Surface, r: Rect, top: Color, bottom: Color) void {
        const area = self.clipped(r);
        if (area.isEmpty() or r.h == 0) return;

        var y = area.y;
        while (y < area.bottom()) : (y += 1) {
            const t = @as(u32, @intCast(y - r.y)) * 255 / @as(u32, @intCast(@max(r.h, 1)));
            const c = lerp(top, bottom, @intCast(t));
            self.fill(.{ .x = area.x, .y = y, .w = area.w, .h = 1 }, c);
        }
    }

    pub fn outline(self: *const Surface, r: Rect, c: Color, thickness: i32) void {
        self.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = thickness }, c);
        self.fill(.{ .x = r.x, .y = r.bottom() - thickness, .w = r.w, .h = thickness }, c);
        self.fill(.{ .x = r.x, .y = r.y, .w = thickness, .h = r.h }, c);
        self.fill(.{ .x = r.right() - thickness, .y = r.y, .w = thickness, .h = r.h }, c);
    }

    /// Darken a region — a cheap stand-in for a real blurred drop shadow.
    pub fn shade(self: *const Surface, r: Rect, amount: u8) void {
        const area = self.clipped(r);
        if (area.isEmpty()) return;

        var y = area.y * self.scale;
        while (y < area.bottom() * self.scale) : (y += 1) {
            const row = @as(usize, @intCast(y * self.stride));
            var x = area.x * self.scale;
            while (x < area.right() * self.scale) : (x += 1) {
                const i = row + @as(usize, @intCast(x));
                self.pixels[i] = darken(self.pixels[i], amount);
            }
        }
    }
};

const FROST_W = 384;
const FROST_H = 256;
var frost_a: [FROST_W * FROST_H]u32 = undefined;
var frost_b: [FROST_W * FROST_H]u32 = undefined;

fn blurPass(src: []const u32, dst: []u32, width: i32, height: i32, horizontal: bool) void {
    var y: i32 = 0;
    while (y < height) : (y += 1) {
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            var red: u32 = 0;
            var green: u32 = 0;
            var blue: u32 = 0;
            var delta: i32 = -3;
            while (delta <= 3) : (delta += 1) {
                const sx = if (horizontal) @max(0, @min(width - 1, x + delta)) else x;
                const sy = if (horizontal) y else @max(0, @min(height - 1, y + delta));
                const c = src[@intCast(sy * width + sx)];
                red += (c >> 16) & 255;
                green += (c >> 8) & 255;
                blue += c & 255;
            }
            dst[@intCast(y * width + x)] = ((red / 7) << 16) | ((green / 7) << 8) | (blue / 7);
        }
    }
}

/// Dependency closure helper: glass must be reconstructed in full whenever
/// any of its backdrop changes. Repeated by the compositor for stacked glass.
pub fn expandForGlass(damage: Rect, glass: Rect) Rect {
    return if (Rect.overlaps(damage, glass)) Rect.unionWith(damage, glass) else damage;
}

test "frost spreads backdrop edges and confines all writes to damage" {
    const std = @import("std");
    var pixels: [64 * 32]u32 = undefined;
    var s = Surface{ .pixels = &pixels, .width = 64, .height = 32, .stride = 64 };
    const full = Rect{ .x = 0, .y = 0, .w = 64, .h = 32 };
    s.fill(full, 0x101010);
    s.fill(.{ .x = 32, .y = 0, .w = 32, .h = 32 }, 0xF0F0F0);
    const original = pixels;
    s.setClip(.{ .x = 16, .y = 8, .w = 32, .h = 16 });
    s.frost(full, 0, 0, 0);
    try std.testing.expect(s.getPhysical(28, 16) > 0x101010);
    try std.testing.expect(s.getPhysical(36, 16) < 0xF0F0F0);
    for (0..32) |y| for (0..64) |x| {
        if (x < 16 or x >= 48 or y < 8 or y >= 24) try std.testing.expectEqual(original[y * 64 + x], pixels[y * 64 + x]);
    };
    const rendered = pixels;
    pixels = original; // reconstruct underlying layer, as Peel does
    s.frost(full, 0, 0, 0);
    try std.testing.expectEqualSlices(u32, &rendered, &pixels);
}

test "glass damage grows to its dependency and skips unrelated surfaces" {
    const std = @import("std");
    const glass = Rect{ .x = 10, .y = 10, .w = 100, .h = 30 };
    try std.testing.expectEqualDeep(glass, expandForGlass(.{ .x = 20, .y = 20, .w = 2, .h = 2 }, glass));
    const far = Rect{ .x = 200, .y = 200, .w = 5, .h = 5 };
    try std.testing.expectEqualDeep(far, expandForGlass(far, glass));
}

test "frost cache matches uncached pixels and invalidates changed backdrops" {
    const std = @import("std");
    var cache: FrostCache(1024) = .{};
    var pixels: [1024]u32 = undefined;
    var s = Surface{ .pixels = &pixels, .width = 16, .height = 16, .stride = 32, .scale = 2 };
    const full = Rect{ .x = 0, .y = 0, .w = 16, .h = 16 };
    for (0..5) |iteration| {
        for (&pixels, 0..) |*p, i| p.* = @intCast(i * 900 + (if (iteration > 1) @as(usize, 500) else 0));
        const original = pixels;
        if (iteration == 3) s.setClip(.{ .x = 2, .y = 3, .w = 4, .h = 5 }) else s.resetClip();
        s.frost(full, 4, 0xCCDDFF, 170);
        const expected = pixels;
        pixels = original;
        cache.paint(&s, full, 4, 0xCCDDFF, 170);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
    try std.testing.expectEqual(@as(usize, 2), cache.hits);
    // A resized or differently tinted surface must not reuse the old material.
    s.fill(full, 0x8899AA);
    cache.paint(&s, .{ .x = 1, .y = 1, .w = 12, .h = 12 }, 3, 0xFFFFFF, 100);
    try std.testing.expectEqual(@as(usize, 2), cache.hits);
}

test "2x fill and rounded drawing obey logical damage clipping" {
    const std = @import("std");
    var pixels = [_]u32{0} ** 256;
    var surface = Surface{ .pixels = &pixels, .width = 8, .height = 8, .stride = 16, .scale = 2 };
    surface.setClip(.{ .x = 2, .y = 2, .w = 3, .h = 3 });
    surface.fill(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, 0xFFFFFF);
    for (0..16) |y| for (0..16) |x| {
        try std.testing.expectEqual(if (x >= 4 and x < 10 and y >= 4 and y < 10) @as(u32, 0xFFFFFF) else 0, pixels[y * 16 + x]);
    };
    surface.rounded(.{ .x = 0, .y = 0, .w = 8, .h = 8 }, 4, 0xFF8800, 255);
    for (0..16) |y| for (0..16) |x| {
        if (x < 4 or x >= 10 or y < 4 or y >= 10) try std.testing.expectEqual(@as(u32, 0), pixels[y * 16 + x]);
    };
}

test "cached dock shadow is identical and partial repaint stays clipped" {
    const std = @import("std");
    var cache: FrostCache(4096) = .{};
    var pixels: [4096]u32 = undefined;
    var s = Surface{ .pixels = &pixels, .width = 32, .height = 32, .stride = 64, .scale = 2 };
    const r = Rect{ .x = 10, .y = 2, .w = 12, .h = 12 };
    for (0..4) |iteration| {
        for (&pixels, 0..) |*p, i| p.* = @intCast(i * 700 + (if (iteration > 1) @as(usize, 400) else 0));
        const original = pixels;
        if (iteration == 3) s.setClip(.{ .x = 10, .y = 4, .w = 5, .h = 6 }) else s.resetClip();
        var spread: i32 = 8;
        while (spread > 0) : (spread -= 1) s.rounded(.{ .x = r.x - spread, .y = r.y + 3, .w = r.w + spread * 2, .h = r.h + spread }, 4 + spread, 0x333153, 4);
        s.frost(r, 4, 0xEAEAFB, 104);
        const expected = pixels;
        pixels = original;
        cache.paintShadowed(&s, r, 4, 0xEAEAFB, 104);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
    try std.testing.expectEqual(@as(usize, 1), cache.hits);
}

pub fn lerp(a: Color, b: Color, t: u8) Color {
    const ar = (a >> 16) & 0xFF;
    const ag = (a >> 8) & 0xFF;
    const ab = a & 0xFF;
    const br = (b >> 16) & 0xFF;
    const bg = (b >> 8) & 0xFF;
    const bb = b & 0xFF;
    const tt: u32 = t;
    const r = (ar * (255 - tt) + br * tt) / 255;
    const g = (ag * (255 - tt) + bg * tt) / 255;
    const bl = (ab * (255 - tt) + bb * tt) / 255;
    return (r << 16) | (g << 8) | bl;
}

pub fn darken(c: Color, amount: u8) Color {
    const r = ((c >> 16) & 0xFF) * (255 - @as(u32, amount)) / 255;
    const g = ((c >> 8) & 0xFF) * (255 - @as(u32, amount)) / 255;
    const b = (c & 0xFF) * (255 - @as(u32, amount)) / 255;
    return (r << 16) | (g << 8) | b;
}
