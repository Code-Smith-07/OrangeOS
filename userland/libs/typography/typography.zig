//! Allocation-free Inter coverage-atlas renderer. Atlas font data is licensed
//! under SIL OFL 1.1; see assets/fonts/OFL-Inter.txt. Renderer code follows the
//! repository license. tools/fontconv/desktop_font.py regenerates the atlas.
const data = @embedFile("inter-atlas.bin");

pub const Glyph = struct {
    pixels: []const u8,
    width: i32,
    height: i32,
    x: i32,
    y: i32,
    advance: i32,
};

pub fn glyph(c: u8, scale: i32) Glyph {
    return atlasGlyph(data, c, scale, 8);
}
fn atlasGlyph(atlas: []const u8, c: u8, scale: i32, max_scale: i32) Glyph {
    const code: usize = if (c >= 32 and c <= 126) c - 32 else '?' - 32;
    const size: usize = @intCast(@max(1, @min(max_scale, scale)) - 1);
    const p = (size * 95 + code) * 12;
    const offset = @as(usize, atlas[p]) | (@as(usize, atlas[p + 1]) << 8) | (@as(usize, atlas[p + 2]) << 16) | (@as(usize, atlas[p + 3]) << 24);
    const w: usize = atlas[p + 4];
    const h: usize = atlas[p + 5];
    return .{ .pixels = atlas[offset..][0 .. w * h], .width = @intCast(w), .height = @intCast(h), .x = @as(i8, @bitCast(atlas[p + 6])), .y = @as(i8, @bitCast(atlas[p + 7])), .advance = atlas[p + 8] };
}

pub fn blend(bg: u32, fg: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    var color: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shift| {
        color |= (((bg >> shift & 255) * (255 - a) + (fg >> shift & 255) * a) / 255) << shift;
    }
    return color;
}

pub fn drawChar(target: anytype, c: u8, x: i32, y: i32, scale: i32, color: u32) void {
    paintGlyph(target, glyph(c, scale * target.scale), x, y, scale, color);
}
pub fn drawMono(target: anytype, c: u8, x: i32, y: i32, color: u32) void {
    paintGlyph(target, atlasGlyph(@embedFile("mono-atlas.bin"), c, target.scale, 2), x, y, 1, color);
}
fn paintGlyph(target: anytype, g: Glyph, x: i32, y: i32, scale: i32, color: u32) void {
    const backing = target.scale;
    var row: i32 = 0;
    while (row < g.height) : (row += 1) {
        const yy = y * backing + g.y + row - scale * backing * 2;
        if (yy < 0 or yy >= target.height * backing) continue;
        var col: i32 = 0;
        while (col < g.width) : (col += 1) {
            const xx = x * backing + g.x + col;
            if (xx < 0 or xx >= target.width * backing) continue;
            const a = g.pixels[@intCast(row * g.width + col)];
            if (a == 0) continue;
            target.putPhysical(xx, yy, blend(target.getPhysical(xx, yy), color, a));
        }
    }
}

pub fn drawText(target: anytype, str: []const u8, x: i32, y: i32, scale: i32, color: u32) void {
    var xx = x;
    for (str) |c| {
        drawChar(target, c, xx, y, scale, color);
        xx += glyph(c, scale).advance;
    }
}

pub fn textWidth(str: []const u8, scale: i32) i32 {
    var width: i32 = 0;
    for (str) |c| width += glyph(c, scale).advance;
    return width;
}
