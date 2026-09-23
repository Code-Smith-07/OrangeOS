//! Peel's software renderer.
//!
//! Everything is a CPU store into a 32-bit ARGB buffer. No GPU is involved and
//! A 1280x800 logical desktop at 2x has a 16 MB backing buffer. Damage
//! tracking keeps most updates small; frosted surfaces expand their damage.

pub const Color = u32;

/// Exact changed pixels, rounded out to logical coordinates for IPC damage.
pub fn changedPixelBounds(before: []const u32, after: []const u32, stride: i32, scale: i32) Rect {
    const std = @import("std");
    std.debug.assert(before.len == after.len and stride > 0 and scale > 0);
    const width: usize = @intCast(stride);
    std.debug.assert(before.len % width == 0);
    var left = width;
    var right: usize = 0;
    var top = before.len / width;
    var bottom: usize = 0;
    for (0..before.len / width) |row| {
        const a = before[row * width ..][0..width];
        const b = after[row * width ..][0..width];
        if (std.mem.eql(u32, a, b)) continue;
        top = @min(top, row);
        bottom = row + 1;
        for (a, b, 0..) |old, new, col| if (old != new) {
            left = @min(left, col);
            right = @max(right, col + 1);
        };
    }
    if (right == 0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const x = @divTrunc(@as(i32, @intCast(left)), scale);
    const y = @divTrunc(@as(i32, @intCast(top)), scale);
    return .{ .x = x, .y = y, .w = @divTrunc(@as(i32, @intCast(right)) + scale - 1, scale) - x, .h = @divTrunc(@as(i32, @intCast(bottom)) + scale - 1, scale) - y };
}

test "changed pixels cover first last and odd backing coordinates" {
    const std = @import("std");
    const before = [_]u32{0} ** 64;
    var after = before;
    try std.testing.expect(changedPixelBounds(&before, &after, 8, 2).isEmpty());
    after[3 * 8 + 5] = 1;
    try std.testing.expectEqualDeep(Rect{ .x = 2, .y = 1, .w = 1, .h = 1 }, changedPixelBounds(&before, &after, 8, 2));
    after[0] = 1;
    after[63] = 1;
    try std.testing.expectEqualDeep(Rect{ .x = 0, .y = 0, .w = 4, .h = 4 }, changedPixelBounds(&before, &after, 8, 2));
}

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
        /// Trusted compositor-only hint; all changed backdrop pixels must be
        /// inside it. Null performs the full exact comparison.
        source_damage: ?Rect = null,
        last_damage: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
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
            self.last_damage = area;
            if (area.isEmpty()) return;
            const width: usize = @intCast(area.w * s.scale);
            const height: usize = @intCast(area.h * s.scale);
            if (!std.meta.eql(area, bounds) or width * height > capacity) {
                render(s, r, radius, tint, opacity, shadow);
                return;
            }
            const key = Key{ .rect = r, .bounds = bounds, .scale = s.scale, .radius = radius, .tint = tint, .opacity = opacity, .shadow = shadow };
            const same_key = self.valid and std.meta.eql(self.key, key);
            var matches = same_key;
            var min_x: usize = width;
            var min_y: usize = height;
            var max_x: usize = 0;
            var max_y: usize = 0;
            const scan = if (same_key and !shadow and self.source_damage != null) Rect.intersect(area, self.source_damage.?) else area;
            const scan_left: usize = if (scan.isEmpty()) 0 else @intCast((scan.x - area.x) * s.scale);
            const scan_width: usize = if (scan.isEmpty()) 0 else @intCast(scan.w * s.scale);
            const scan_top: usize = if (scan.isEmpty()) 0 else @intCast((scan.y - area.y) * s.scale);
            const scan_height: usize = if (scan.isEmpty()) 0 else @intCast(scan.h * s.scale);
            for (scan_top..scan_top + scan_height) |row| {
                const start: usize = @as(usize, @intCast((area.y * s.scale + @as(i32, @intCast(row))) * s.stride + area.x * s.scale)) + scan_left;
                const source = s.pixels[start..][0..scan_width];
                const saved = self.before[row * width + scan_left ..][0..scan_width];
                if (same_key and !std.mem.eql(u32, source, saved)) {
                    matches = false;
                    min_y = @min(min_y, row);
                    max_y = row;
                    if (!shadow) for (source, saved, 0..) |now, old, col| {
                        if (now != old) {
                            min_x = @min(min_x, col + scan_left);
                            max_x = @max(max_x, col + scan_left);
                        }
                    };
                }
                @memcpy(saved, source);
            }
            var dirty = area;
            if (same_key and !matches and !shadow) {
                // Two radius-3 separable blur passes have radius 6 cells.
                // Include downsample/bilinear support and AA/backdrop pixels.
                // Samples still come from the FULL fresh source, never cached
                // glass. Only reconstruction/publication is restricted.
                const step = @max(4, @max(@divTrunc(bounds.w + FROST_W - 1, FROST_W), @divTrunc(bounds.h + FROST_H - 1, FROST_H)));
                const pad = step * 8;
                const x = area.x + @divTrunc(@as(i32, @intCast(min_x)), s.scale);
                const y = area.y + @divTrunc(@as(i32, @intCast(min_y)), s.scale);
                const right = area.x + @divTrunc(@as(i32, @intCast(max_x)), s.scale) + 1;
                const bottom = area.y + @divTrunc(@as(i32, @intCast(max_y)), s.scale) + 1;
                dirty = Rect.intersect(area, .{ .x = x - pad, .y = y - pad, .w = right - x + pad * 2, .h = bottom - y + pad * 2 });
            }
            if (!matches) {
                var clipped = s.*;
                clipped.setClip(dirty);
                render(&clipped, r, radius, tint, opacity, shadow);
            }
            self.last_damage = if (matches) .{ .x = 0, .y = 0, .w = 0, .h = 0 } else dirty;
            for (0..height) |row| {
                const start: usize = @intCast((area.y * s.scale + @as(i32, @intCast(row))) * s.stride + area.x * s.scale);
                const target = s.pixels[start..][0..width];
                const saved = self.after[row * width ..][0..width];
                const y = area.y * s.scale + @as(i32, @intCast(row));
                if (matches or y < dirty.y * s.scale or y >= dirty.bottom() * s.scale) {
                    @memcpy(target, saved);
                } else {
                    const left: usize = @intCast((dirty.x - area.x) * s.scale);
                    const right: usize = @intCast((dirty.right() - area.x) * s.scale);
                    @memcpy(target[0..left], saved[0..left]);
                    @memcpy(saved[left..right], target[left..right]);
                    @memcpy(target[right..], saved[right..]);
                }
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

// Exact repeated RGB blend tables for straight window-shadow edges. Unlike
// collapsing layers into one alpha, this preserves each layer's rounding.
const shadow_tables = tables: {
    @setEvalBranchQuota(1_000_000);
    var result: [2][14][2][3][256]u8 = undefined;
    for (0..2) |active| for (0..14) |count| for (0..2) |edge| for (0..3) |channel| for (0..256) |value| {
        var out: u32 = @intCast(value);
        const tint = ([_]u32{ 0x1F, 0x18, 0x3C })[channel];
        const alpha: u32 = if (active == 1) 5 else 3;
        for (0..count) |layer| {
            const a = alpha - @intFromBool(edge == 1 and layer + 1 == count);
            out = (out * (255 - a) + tint * a) / 255;
        }
        result[active][count][edge][channel][value] = @intCast(out);
    };
    break :tables result;
};

pub fn windowShadow(s: *const Surface, r: Rect, active: bool) void {
    windowShadowImpl(s, r, active, true, true);
}

// Rounded shadow geometry is translation-invariant at normal window sizes.
// Cache only the exact thirteen alpha operations, NOT finished backdrop pixels:
// moving windows and live applications always receive the current backdrop.
// Horizontal corners are mirror images, so two masks cover all four corners.
// Four bounded entries cover active/inactive shadows at 1x/2x (495,616 bytes).
const SHADOW_CORNER_PIXELS = 44 * (38 + 50) * 4;
var shadow_corner_masks: [2][2][SHADOW_CORNER_PIXELS]u64 = undefined;
var shadow_corner_valid = [_][2]bool{.{ false, false }} ** 2;
const shadow_single_blends = tables: {
    @setEvalBranchQuota(100_000);
    var result: [6][3][256]u8 = undefined;
    for (0..6) |alpha| for (0..3) |channel| for (0..256) |value| {
        const tint = ([_]usize{ 0x1F, 0x18, 0x3C })[channel];
        result[alpha][channel][value] = @intCast((value * (255 - alpha) + tint * alpha) / 255);
    };
    break :tables result;
};

fn shadowCornerMasks(scale: i32, active: bool) []const u64 {
    const si: usize = @intCast(scale - 1);
    const ai = @intFromBool(active);
    const masks = &shadow_corner_masks[si][ai];
    if (shadow_corner_valid[si][ai]) return masks;
    const width: usize = @intCast(44 * scale);
    var offset: usize = 0;
    for ([_]bool{ false, true }) |bottom| {
        const height: usize = @intCast((if (bottom) @as(i32, 50) else 38) * scale);
        for (0..height) |row| for (0..width) |col| {
            const x = @as(i32, @intCast(col)) - 14 * scale;
            const y = @as(i32, @intCast(row)) + (if (bottom) @as(i32, 34) else -8) * scale;
            // Original renderer paints the outside fringe plus 13-point
            // interior corner cutouts. Keep the remaining interior untouched.
            const eligible = x < 0 or y < 0 or y >= 64 * scale or
                (x < 13 * scale and (y < 13 * scale or y >= 51 * scale));
            var mask: u64 = 0;
            if (eligible) {
                var layer: i32 = 14;
                while (layer >= 2) : (layer -= 1) {
                    if (x < -layer * scale or y < (6 - layer) * scale or
                        x >= (64 + layer) * scale or y >= (70 + layer) * scale) continue;
                    const radius = (16 + layer) * scale;
                    const dx = @max(@max(16 * scale - x - 1, x - 48 * scale), 0);
                    const dy = @max(@max(22 * scale - y - 1, y - 54 * scale), 0);
                    const d = dx * dx + dy * dy;
                    if (d > radius * radius) continue;
                    var alpha: u32 = if (active) 5 else 3;
                    if (d > radius * radius - 2 * radius)
                        alpha = alpha * @as(u32, @intCast(radius * radius - d)) / @as(u32, @intCast(2 * radius));
                    mask |= @as(u64, alpha) << @as(u6, @intCast((14 - layer) * 3));
                    // lerp with zero alpha still canonicalizes the RGB word.
                    mask |= @as(u64, 1) << 63;
                }
            }
            masks[offset + row * width + col] = mask;
        };
        offset += width * height;
    }
    shadow_corner_valid[si][ai] = true;
    return masks;
}

fn paintShadowCorners(s: *const Surface, r: Rect, active: bool) void {
    const masks = shadowCornerMasks(s.scale, active);
    const mask_width: usize = @intCast(44 * s.scale);
    var offset: usize = 0;
    for ([_]bool{ false, true }) |bottom| {
        const height: i32 = if (bottom) 50 else 38;
        for ([_]bool{ false, true }) |right| {
            const patch = Rect{ .x = if (right) r.right() - 30 else r.x - 14, .y = if (bottom) r.bottom() - 30 else r.y - 8, .w = 44, .h = height };
            const area = s.clipped(patch);
            if (area.isEmpty()) continue;
            var y = area.y * s.scale;
            while (y < area.bottom() * s.scale) : (y += 1) {
                const row: usize = @intCast(y - patch.y * s.scale);
                var x = area.x * s.scale;
                while (x < area.right() * s.scale) : (x += 1) {
                    const col: usize = @intCast(x - patch.x * s.scale);
                    const mask_col = if (right) mask_width - 1 - col else col;
                    var mask = masks[offset + row * mask_width + mask_col];
                    if (mask == 0) continue;
                    mask &= ~(@as(u64, 1) << 63);
                    const index: usize = @intCast(y * s.stride + x);
                    const pixel = s.pixels[index];
                    var red = (pixel >> 16) & 255;
                    var green = (pixel >> 8) & 255;
                    var blue = pixel & 255;
                    while (mask != 0) : (mask >>= 3) {
                        const alpha: usize = @intCast(mask & 7);
                        if (alpha == 0) continue;
                        const lut = &shadow_single_blends[alpha];
                        red = lut[0][red];
                        green = lut[1][green];
                        blue = lut[2][blue];
                    }
                    s.pixels[index] = (red << 16) | (green << 8) | blue;
                }
            }
        }
        offset += mask_width * @as(usize, @intCast(height * s.scale));
    }
}

fn windowShadowImpl(s: *const Surface, r: Rect, active: bool, fast: bool, cache_corners: bool) void {
    // Rounded windows expose backdrop INSIDE their rectangular bounds. Paint
    // the shadow there too; the window silhouette masks it during composition.
    // Previously the fringe-only optimization left hard square shadow cutouts.
    const optimized = fast and r.w >= 64 and r.h >= 64;
    const cached_corners = optimized and cache_corners and (s.scale == 1 or s.scale == 2);
    if (cached_corners) paintShadowCorners(s, r, active);
    const corner_size = @min(13, @divTrunc(@min(r.w, r.h), 2));
    var layer: i32 = 14;
    while (!cached_corners and layer >= 2) : (layer -= 1) {
        const shadow = Rect{ .x = r.x - layer, .y = r.y - layer + 6, .w = r.w + layer * 2, .h = r.h + layer * 2 };
        for ([_]i32{ r.y, r.bottom() - corner_size }) |y| for ([_]i32{ r.x, r.right() - corner_size }) |x| {
            var corner = s.*;
            corner.setClip(Rect.intersect(s.clip, .{ .x = x, .y = y, .w = corner_size, .h = corner_size }));
            corner.rounded(shadow, 16 + layer, 0x1F183C, if (active) 5 else 3);
        };
    }
    // Only the corners need rounded coverage evaluated for all thirteen
    // layers. Straight edges use the exact precomputed colour transformation.
    const centers = [_]Rect{
        .{ .x = r.x + 30, .y = r.y - 14, .w = r.w - 60, .h = 14 },
        .{ .x = r.x + 30, .y = r.bottom(), .w = r.w - 60, .h = 20 },
        .{ .x = r.x - 14, .y = r.y + 30, .w = 14, .h = r.h - 60 },
        .{ .x = r.right(), .y = r.y + 30, .w = 14, .h = r.h - 60 },
    };
    var spread: i32 = 14;
    while (!cached_corners and spread >= 2) : (spread -= 1) {
        const shadow = Rect{ .x = r.x - spread, .y = r.y - spread + 6, .w = r.w + spread * 2, .h = r.h + spread * 2 };
        const strips = [_]Rect{
            .{ .x = shadow.x, .y = shadow.y, .w = shadow.w, .h = r.y - shadow.y },
            .{ .x = shadow.x, .y = r.bottom(), .w = shadow.w, .h = shadow.bottom() - r.bottom() },
            .{ .x = shadow.x, .y = r.y, .w = spread, .h = r.h },
            .{ .x = r.right(), .y = r.y, .w = spread, .h = r.h },
        };
        for (strips, 0..) |strip, side| {
            var part = s.*;
            if (optimized) {
                const center = centers[side];
                const ends = if (side < 2) [_]Rect{
                    .{ .x = strip.x, .y = strip.y, .w = center.x - strip.x, .h = strip.h },
                    .{ .x = center.right(), .y = strip.y, .w = strip.right() - center.right(), .h = strip.h },
                } else [_]Rect{
                    .{ .x = strip.x, .y = strip.y, .w = strip.w, .h = center.y - strip.y },
                    .{ .x = strip.x, .y = center.bottom(), .w = strip.w, .h = strip.bottom() - center.bottom() },
                };
                for (ends) |end| {
                    part.setClip(Rect.intersect(s.clip, end));
                    part.rounded(shadow, 16 + spread, 0x1F183C, if (active) 5 else 3);
                }
            } else {
                part.setClip(Rect.intersect(s.clip, strip));
                part.rounded(shadow, 16 + spread, 0x1F183C, if (active) 5 else 3);
            }
        }
    }
    if (!optimized) return;
    for (centers, 0..) |center, side| {
        const area = s.clipped(center);
        if (area.isEmpty()) continue;
        var y = area.y * s.scale;
        while (y < area.bottom() * s.scale) : (y += 1) {
            var x = area.x * s.scale;
            while (x < area.right() * s.scale) : (x += 1) {
                const needed = switch (side) {
                    0 => r.y - @divTrunc(y, s.scale) + 6,
                    1 => @divTrunc(y, s.scale) - r.bottom() - 5,
                    2 => r.x - @divTrunc(x, s.scale),
                    else => @divTrunc(x, s.scale) - r.right() + 1,
                };
                const count: usize = @intCast(@max(0, @as(i32, 15) - @max(2, needed)));
                const outer_pixel = switch (side) {
                    0 => @mod(y, s.scale) == 0,
                    1 => @mod(y, s.scale) == s.scale - 1,
                    2 => @mod(x, s.scale) == 0,
                    else => @mod(x, s.scale) == s.scale - 1,
                };
                const edge = needed >= 2 and needed <= 14 and outer_pixel;
                const lut = &shadow_tables[@intFromBool(active)][count][@intFromBool(edge)];
                const idx: usize = @intCast(y * s.stride + x);
                const c = s.pixels[idx];
                s.pixels[idx] = (@as(u32, lut[0][(c >> 16) & 255]) << 16) | (@as(u32, lut[1][(c >> 8) & 255]) << 8) | lut[2][c & 255];
            }
        }
    }
}

test "fast window shadows exactly match layered shadows at 1x and 2x" {
    const std = @import("std");
    var pixels: [280 * 260]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| for ([_]bool{ false, true }) |active| for (0..3) |variant| {
        for (&pixels, 0..) |*p, i| p.* = @intCast((i * 1987) & 0xFFFFFF);
        const original = pixels;
        var s = Surface{ .pixels = &pixels, .width = 140, .height = 130, .stride = 140 * scale, .scale = scale };
        const r = if (variant == 0) Rect{ .x = 20, .y = 20, .w = 90, .h = 80 } else Rect{ .x = -4, .y = -3, .w = 104, .h = 99 };
        if (variant == 2) s.setClip(.{ .x = 3, .y = 4, .w = 87, .h = 102 });
        windowShadowImpl(&s, r, active, false, false);
        const expected = pixels;
        pixels = original;
        windowShadow(&s, r, active);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    };
}

test "shadow masks preserve live backdrop changes, minimum geometry and clipped translations" {
    const std = @import("std");
    const pixels = try std.testing.allocator.alloc(u32, 144 * 136 * 9);
    defer std.testing.allocator.free(pixels);
    const original = try std.testing.allocator.alloc(u32, pixels.len);
    defer std.testing.allocator.free(original);
    const expected = try std.testing.allocator.alloc(u32, pixels.len);
    defer std.testing.allocator.free(expected);
    for ([_]i32{ 1, 2, 3 }) |scale| for (0..12) |iteration| {
        // Vary all 32 bits so even zero-alpha RGB canonicalization is covered.
        for (pixels, 0..) |*p, i| p.* = @truncate((i + iteration * 773) *% 917_813);
        @memcpy(original, pixels);
        var s = Surface{ .pixels = pixels.ptr, .width = 144, .height = 136, .stride = 144 * scale, .scale = scale };
        const r = Rect{ .x = @as(i32, @intCast(iteration)) * 5 - 20, .y = @as(i32, @intCast(iteration)) * 4 - 16, .w = 62 + @as(i32, @intCast(iteration)) * 3, .h = 64 + @as(i32, @intCast(iteration)) * 2 };
        if (iteration % 3 != 0) s.setClip(.{ .x = 7, .y = 9, .w = 109, .h = 99 });
        windowShadowImpl(&s, r, iteration % 2 == 0, true, false);
        @memcpy(expected, pixels);
        @memcpy(pixels, original);
        windowShadow(&s, r, iteration % 2 == 0);
        try std.testing.expectEqualSlices(u32, expected, pixels);
    };
}

test "optional native shadow microbenchmark" {
    const std = @import("std");
    if (!std.process.hasEnvVarConstant("ORANGE_SHADOW_BENCH")) return;
    const pixels = try std.testing.allocator.alloc(u32, 1280 * 800 * 4);
    defer std.testing.allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @truncate(i *% 917_813);
    const s = Surface{ .pixels = pixels.ptr, .width = 1280, .height = 800, .stride = 2560, .scale = 2 };
    const r = Rect{ .x = 160, .y = 120, .w = 580, .h = 410 };
    // Keep a cold native measurement separate from warm moving-window work.
    shadow_corner_valid[1][1] = false;
    var timer = try std.time.Timer.start();
    windowShadow(&s, r, true);
    const cold = timer.read();
    var times: [2]u64 = undefined;
    for ([_]bool{ false, true }, 0..) |cached, mode| {
        timer.reset();
        for (0..160) |frame| {
            var moved = r;
            moved.x += @as(i32, @intCast(frame % 11));
            windowShadowImpl(&s, moved, true, true, cached);
        }
        times[mode] = timer.read() / 160;
    }
    std.debug.print("\n2x native shadow: cold {d} us; previous straight-edge fast path {d} us; cached corners {d} us (not guest timings)\n", .{ cold / 1000, times[0] / 1000, times[1] / 1000 });
    std.mem.doNotOptimizeAway(pixels);
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
        self.frostImpl(r, radius, tint, opacity, false, true);
    }
    pub fn frostTop(self: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8) void {
        self.frostImpl(r, radius, tint, opacity, true, true);
    }
    fn frostImpl(self: *const Surface, r: Rect, radius: i32, tint: Color, opacity: u8, top_only: bool, fast: bool) void {
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
        const cached = fast and area.w * sc <= frost_top.len;
        var last_y0: i32 = -1;
        y = area.y * sc;
        while (y < area.bottom() * sc) : (y += 1) {
            const fy = @max(0, @divTrunc((y - bounds.y * sc) * 256, step * sc) - 128);
            const y0 = @min(height - 1, fy >> 8);
            const y1 = @min(height - 1, y0 + 1);
            if (cached and y0 != last_y0) {
                var xx = area.x * sc;
                while (xx < area.right() * sc) : (xx += 1) {
                    const fx = @max(0, @divTrunc((xx - bounds.x * sc) * 256, step * sc) - 128);
                    const x0 = @min(width - 1, fx >> 8);
                    const x1 = @min(width - 1, x0 + 1);
                    const index: usize = @intCast(xx - area.x * sc);
                    frost_top[index] = lerp(frost_a[@intCast(y0 * width + x0)], frost_a[@intCast(y0 * width + x1)], @intCast(fx & 255));
                    frost_bottom[index] = lerp(frost_a[@intCast(y1 * width + x0)], frost_a[@intCast(y1 * width + x1)], @intCast(fx & 255));
                }
                last_y0 = y0;
            }
            var x = area.x * sc;
            while (x < area.right() * sc) : (x += 1) {
                const dx = @max(@max(r.x * sc + rad - x - 1, x - (r.right() * sc - rad)), 0);
                const dy = if (top_only) @max(r.y * sc + rad - y - 1, 0) else @max(@max(r.y * sc + rad - y - 1, y - (r.bottom() * sc - rad)), 0);
                const d = dx * dx + dy * dy;
                if (d > rad * rad) continue;
                const fx = @max(0, @divTrunc((x - bounds.x * sc) * 256, step * sc) - 128);
                const x0 = @min(width - 1, fx >> 8);
                const x1 = @min(width - 1, x0 + 1);
                const index: usize = @intCast(x - area.x * sc);
                const top = if (cached) frost_top[index] else lerp(frost_a[@intCast(y0 * width + x0)], frost_a[@intCast(y0 * width + x1)], @intCast(fx & 255));
                const bottom = if (cached) frost_bottom[index] else lerp(frost_a[@intCast(y1 * width + x0)], frost_a[@intCast(y1 * width + x1)], @intCast(fx & 255));
                const diffused = lerp(top, bottom, @intCast(fy & 255));
                const material = lerp(diffused, tint, opacity);
                const edge = @max(1, 2 * rad);
                const coverage: u8 = if (rad > 0 and d > rad * rad - edge) @intCast(@divTrunc((rad * rad - d) * 255, edge)) else 255;
                // The loop is already confined to clipped physical bounds.
                const target: usize = @intCast(y * self.stride + x);
                self.pixels[target] = if (coverage == 255) material else lerp(self.pixels[target], material, coverage);
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
// Horizontal interpolation repeats for each row in a downsample cell. Keep
// exact rounded RGB results; no lower-resolution final surface or changed AA.
var frost_top: [4096]u32 = undefined;
var frost_bottom: [4096]u32 = undefined;

test "row-cached frost exactly matches scalar reconstruction" {
    const std = @import("std");
    var pixels: [96 * 80 * 4]u32 = undefined;
    for ([_]i32{ 1, 2 }) |scale| for ([_]bool{ false, true }) |top_only| for (0..3) |clip| {
        for (&pixels, 0..) |*p, i| p.* = @intCast((i * 71893) & 0xFFFFFF);
        const original = pixels;
        var s = Surface{ .pixels = &pixels, .width = 96, .height = 80, .stride = 96 * scale, .scale = scale };
        if (clip == 1) s.setClip(.{ .x = 7, .y = 8, .w = 60, .h = 42 });
        const r = Rect{ .x = if (clip == 2) -4 else 2, .y = 3, .w = 91, .h = 75 };
        s.frostImpl(r, 18, 0x22243D, 168, top_only, false);
        const expected = pixels;
        pixels = original;
        s.frostImpl(r, 18, 0x22243D, 168, top_only, true);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    };
}

fn blurPass(src: []const u32, dst: []u32, width: i32, height: i32, horizontal: bool) void {
    const lines = if (horizontal) height else width;
    const length = if (horizontal) width else height;
    const step = if (horizontal) @as(i32, 1) else width;
    var line: i32 = 0;
    while (line < lines) : (line += 1) {
        const start = if (horizontal) line * width else line;
        var red: u32 = 0;
        var green: u32 = 0;
        var blue: u32 = 0;
        var delta: i32 = -3;
        while (delta <= 3) : (delta += 1) {
            const c = src[@intCast(start + @max(0, @min(length - 1, delta)) * step)];
            red += (c >> 16) & 255;
            green += (c >> 8) & 255;
            blue += c & 255;
        }
        var at: i32 = 0;
        while (at < length) : (at += 1) {
            dst[@intCast(start + at * step)] = ((red / 7) << 16) | ((green / 7) << 8) | (blue / 7);
            const old = src[@intCast(start + @max(0, at - 3) * step)];
            const new = src[@intCast(start + @min(length - 1, at + 4) * step)];
            red = red - ((old >> 16) & 255) + ((new >> 16) & 255);
            green = green - ((old >> 8) & 255) + ((new >> 8) & 255);
            blue = blue - (old & 255) + (new & 255);
        }
    }
}

test "rolling blur is exactly the seven-tap clamped convolution" {
    const std = @import("std");
    var source: [21 * 17]u32 = undefined;
    for (&source, 0..) |*p, i| p.* = @intCast((i * 18271) & 0xFFFFFF);
    var actual: [21 * 17]u32 = undefined;
    for ([_][2]i32{ .{ 1, 1 }, .{ 2, 3 }, .{ 21, 17 } }) |size| for ([_]bool{ false, true }) |horizontal| {
        blurPass(&source, &actual, size[0], size[1], horizontal);
        for (0..@intCast(size[0] * size[1])) |i| {
            const x = @mod(@as(i32, @intCast(i)), size[0]);
            const y = @divTrunc(@as(i32, @intCast(i)), size[0]);
            var red: u32 = 0;
            var green: u32 = 0;
            var blue: u32 = 0;
            var delta: i32 = -3;
            while (delta <= 3) : (delta += 1) {
                const sx = if (horizontal) std.math.clamp(x + delta, 0, size[0] - 1) else x;
                const sy = if (horizontal) y else std.math.clamp(y + delta, 0, size[1] - 1);
                const c = source[@intCast(sy * size[0] + sx)];
                red += (c >> 16) & 255;
                green += (c >> 8) & 255;
                blue += c & 255;
            }
            try std.testing.expectEqual(((red / 7) << 16) | ((green / 7) << 8) | (blue / 7), actual[i]);
        }
    };
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

test "incremental frost halo exactly matches full repaint after local mutations" {
    const std = @import("std");
    const capacity = 180 * 130 * 4;
    const cache = try std.testing.allocator.create(FrostCache(capacity));
    defer std.testing.allocator.destroy(cache);
    const source = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(source);
    const pixels = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(pixels);
    const expected = try std.testing.allocator.alloc(u32, capacity);
    defer std.testing.allocator.free(expected);
    for ([_]i32{ 1, 2 }) |scale| {
        cache.* = .{};
        for (source, 0..) |*p, i| p.* = @intCast((i * 91813) & 0xFFFFFF);
        var s = Surface{ .pixels = pixels.ptr, .width = 180, .height = 130, .stride = 180 * scale, .scale = scale };
        const r = Rect{ .x = 0, .y = 0, .w = 180, .h = 130 };
        for (0..30) |iteration| {
            const pos = (iteration * 3191) % @as(usize, @intCast(180 * 130 * scale * scale));
            source[pos] ^= 0xFFFFFF;
            // Include patches large enough to hit every downsample phase,
            // not only isolated pixels which the four-tap sampler may skip.
            const stride: usize = @intCast(180 * scale);
            const x = (iteration * 13) % (stride - 9);
            const y = (iteration * 7) % (@as(usize, @intCast(130 * scale)) - 7);
            for (0..7) |dy| for (0..9) |dx| {
                source[(y + dy) * stride + x + dx] ^= 0x9F7F3F;
            };
            @memcpy(pixels, source);
            s.frost(r, 18, 0x22243D, 168);
            @memcpy(expected, pixels);
            @memcpy(pixels, source);
            const point = Rect{ .x = @intCast((pos % stride) / @as(usize, @intCast(scale))), .y = @intCast((pos / stride) / @as(usize, @intCast(scale))), .w = 1, .h = 1 };
            const patch = Rect{ .x = @intCast(x / @as(usize, @intCast(scale))), .y = @intCast(y / @as(usize, @intCast(scale))), .w = 10, .h = 8 };
            cache.source_damage = if (iteration % 2 == 0) Rect.unionWith(point, patch) else null;
            cache.paint(&s, r, 18, 0x22243D, 168);
            try std.testing.expectEqualSlices(u32, expected, pixels);
        }
    }
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
