//! Linear framebuffer abstraction over what Limine hands us.
//!
//! No GPU driver is involved: the bootloader sets a video mode and gives us a
//! pointer to write pixels into. Everything drawn in Phase 0 is a CPU store.

const limine = @import("../../boot/limine_req.zig");

pub const Color = u32;

pub const Fb = struct {
    base: [*]volatile u8,
    width: usize,
    height: usize,
    pitch: usize, // bytes per scanline — may exceed width * 4
    bpp: u16,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,

    /// Pack r/g/b into this framebuffer's native pixel layout.
    pub fn rgb(self: *const Fb, r: u8, g: u8, b: u8) Color {
        return (@as(u32, r) << @intCast(self.red_shift)) |
            (@as(u32, g) << @intCast(self.green_shift)) |
            (@as(u32, b) << @intCast(self.blue_shift));
    }

    pub inline fn putPixel(self: *const Fb, x: usize, y: usize, c: Color) void {
        if (x >= self.width or y >= self.height) return;
        const offset = y * self.pitch + x * 4;
        const p: *volatile u32 = @ptrCast(@alignCast(self.base + offset));
        p.* = c;
    }

    pub fn fillRect(self: *const Fb, x: usize, y: usize, w: usize, h: usize, c: Color) void {
        const x1 = @min(x + w, self.width);
        const y1 = @min(y + h, self.height);
        var yy = y;
        while (yy < y1) : (yy += 1) {
            var xx = x;
            while (xx < x1) : (xx += 1) self.putPixel(xx, yy, c);
        }
    }

    pub fn clear(self: *const Fb, c: Color) void {
        self.fillRect(0, 0, self.width, self.height, c);
    }
};

var fb: ?Fb = null;

/// Pick the first framebuffer Limine reports. Returns null if the bootloader
/// gave us none, or gave us one in a pixel format we don't handle yet.
pub fn init() ?*const Fb {
    const resp = limine.framebuffers() orelse return null;
    if (resp.framebuffer_count == 0) return null;

    const f = resp.framebuffers[0];
    if (f.memory_model != limine.MEMORY_MODEL_RGB) return null;
    if (f.bpp != 32) return null; // Phase 0 handles 32bpp only

    fb = Fb{
        .base = f.address,
        .width = @intCast(f.width),
        .height = @intCast(f.height),
        .pitch = @intCast(f.pitch),
        .bpp = f.bpp,
        .red_shift = f.red_mask_shift,
        .green_shift = f.green_mask_shift,
        .blue_shift = f.blue_mask_shift,
    };
    return &fb.?;
}

pub fn get() ?*const Fb {
    if (fb) |*f| return f;
    return null;
}
