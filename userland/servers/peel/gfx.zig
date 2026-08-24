//! Peel's software renderer.
//!
//! Everything is a CPU store into a 32-bit ARGB buffer. No GPU is involved and
//! none is needed: a full 1280x800 redraw is about 4 MB, and with damage
//! tracking a typical frame touches a small fraction of that.

pub const Color = u32;

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

pub const Surface = struct {
    pixels: [*]u32,
    width: i32,
    height: i32,
    /// Pixels per row, which may exceed width.
    stride: i32,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
    }

    pub inline fn put(self: *const Surface, x: i32, y: i32, c: Color) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.pixels[@intCast(y * self.stride + x)] = c;
    }

    pub fn fill(self: *const Surface, r: Rect, c: Color) void {
        const clipped = Rect.intersect(r, .{ .x = 0, .y = 0, .w = self.width, .h = self.height });
        if (clipped.isEmpty()) return;

        var y = clipped.y;
        while (y < clipped.bottom()) : (y += 1) {
            // Row-at-a-time: the inner loop is a straight run of stores, which
            // is what makes software compositing viable at this resolution.
            const row = @as(usize, @intCast(y * self.stride));
            var x = clipped.x;
            while (x < clipped.right()) : (x += 1) {
                self.pixels[row + @as(usize, @intCast(x))] = c;
            }
        }
    }

    /// Vertical gradient, for the wallpaper.
    pub fn gradient(self: *const Surface, r: Rect, top: Color, bottom: Color) void {
        const clipped = Rect.intersect(r, .{ .x = 0, .y = 0, .w = self.width, .h = self.height });
        if (clipped.isEmpty() or r.h == 0) return;

        var y = clipped.y;
        while (y < clipped.bottom()) : (y += 1) {
            const t = @as(u32, @intCast(y - r.y)) * 255 / @as(u32, @intCast(@max(r.h, 1)));
            const c = lerp(top, bottom, @intCast(t));
            self.fill(.{ .x = clipped.x, .y = y, .w = clipped.w, .h = 1 }, c);
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
        const clipped = Rect.intersect(r, .{ .x = 0, .y = 0, .w = self.width, .h = self.height });
        if (clipped.isEmpty()) return;

        var y = clipped.y;
        while (y < clipped.bottom()) : (y += 1) {
            const row = @as(usize, @intCast(y * self.stride));
            var x = clipped.x;
            while (x < clipped.right()) : (x += 1) {
                const i = row + @as(usize, @intCast(x));
                self.pixels[i] = darken(self.pixels[i], amount);
            }
        }
    }
};

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
