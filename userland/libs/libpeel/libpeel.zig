//! Client library for the Peel display protocol.
//!
//! Hides the port handshake and the shared buffer so an application can say
//! "give me a window" and then draw into an array of pixels.

const pulp = @import("pulp");
pub const proto = @import("protocol.zig");

pub const Error = error{
    NoDisplayServer,
    NoBuffer,
    Rejected,
};

pub const Window = struct {
    id: u32,
    width: i32,
    height: i32,
    scale: i32,
    stride: i32,
    pixels: [*]u32,
    server: i64,
    reply: i64,

    /// Direct access to the window's pixels. Writing here is not visible until
    /// commit() tells Peel which part changed.
    pub inline fn put(self: *const Window, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.fill(x, y, 1, 1, color);
    }

    pub fn putPhysical(self: *const Window, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.width * self.scale or y >= self.height * self.scale) return;
        self.pixels[@intCast(y * self.stride + x)] = color;
    }
    pub fn getPhysical(self: *const Window, x: i32, y: i32) u32 {
        if (x < 0 or y < 0 or x >= self.width * self.scale or y >= self.height * self.scale) return 0;
        return self.pixels[@intCast(y * self.stride + x)];
    }

    pub fn fill(self: *const Window, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        var yy = @max(y, 0) * self.scale;
        const y1 = @min(y + h, self.height) * self.scale;
        const x0 = @max(x, 0) * self.scale;
        const x1 = @min(x + w, self.width) * self.scale;
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) {
                self.pixels[@intCast(yy * self.stride + xx)] = color;
            }
        }
    }

    pub fn clear(self: *const Window, color: u32) void {
        self.fill(0, 0, self.width, self.height, color);
    }

    pub fn rounded(self: *const Window, x: i32, y: i32, w: i32, h: i32, radius: i32, color: u32) void {
        const sc = self.scale;
        const rad = @max(0, @min(radius, @divTrunc(@min(w, h), 2))) * sc;
        var yy = @max(0, y) * sc;
        while (yy < @min(y + h, self.height) * sc) : (yy += 1) {
            var xx = @max(0, x) * sc;
            while (xx < @min(x + w, self.width) * sc) : (xx += 1) {
                const dx = @max(@max(x * sc + rad - xx - 1, xx - ((x + w) * sc - rad)), 0);
                const dy = @max(@max(y * sc + rad - yy - 1, yy - ((y + h) * sc - rad)), 0);
                const d = dx * dx + dy * dy;
                if (d > rad * rad) continue;
                const alpha: u32 = if (rad > 0) @intCast(@min(255, @divTrunc((rad * rad - d) * 255, @max(1, 2 * rad)))) else 255;
                const bg = self.getPhysical(xx, yy);
                var mixed: u32 = 0;
                inline for (.{ 0, 8, 16 }) |shift| mixed |= (((bg >> shift & 255) * (255 - alpha) + (color >> shift & 255) * alpha) / 255) << shift;
                self.putPhysical(xx, yy, mixed);
            }
        }
    }

    /// Tell Peel that a rectangle of the buffer changed.
    pub fn commit(self: *const Window, x: i32, y: i32, w: i32, h: i32) void {
        const msg = proto.Commit{
            .window_id = self.id,
            .x = x,
            .y = y,
            .w = w,
            .h = h,
        };
        const bytes: [*]const u8 = @ptrCast(&msg);
        _ = pulp.portSend(self.server, proto.Op.commit, bytes[0..@sizeOf(proto.Commit)]) catch {};
    }

    pub fn commitAll(self: *const Window) void {
        self.commit(0, 0, self.width, self.height);
    }

    /// Remove this window from Peel before the client process exits.
    pub fn destroy(self: *const Window) void {
        const msg = proto.Destroy{ .window_id = self.id };
        const bytes: [*]const u8 = @ptrCast(&msg);
        _ = pulp.portSend(self.server, proto.Op.destroy, bytes[0..@sizeOf(proto.Destroy)]) catch {};
    }
};

/// Connect to Peel and ask for a window.
pub fn createWindow(title: []const u8, w: i32, h: i32, x: i32, y: i32) Error!Window {
    return createWindowWithFlags(title, w, h, x, y, proto.WindowFlags.closable);
}

pub fn createWindowWithFlags(title: []const u8, w: i32, h: i32, x: i32, y: i32, flags: u32) Error!Window {
    // Seed starts services concurrently. Give the compositor time to publish
    // its port, without an unbounded wait when the display server is absent.
    const server = connect: {
        var attempts: usize = 0;
        while (attempts < 150) : (attempts += 1) {
            if (pulp.portConnect(proto.PORT)) |handle| break :connect handle else |_| {}
            pulp.sleepMs(20);
        }
        return Error.NoDisplayServer;
    };

    const pid = pulp.getpid();

    var reply_name_buf: [32]u8 = undefined;
    const reply_name = proto.replyPortName(&reply_name_buf, pid);
    const reply = pulp.portCreate(reply_name) catch return Error.NoDisplayServer;

    _ = pulp.portSend(server, proto.Op.display_info, @import("std").mem.asBytes(&pid)) catch return Error.Rejected;
    var display: [8]u8 = undefined;
    const dn = pulp.portRecv(reply, &display, true) catch return Error.Rejected;
    if (dn != 4) return Error.Rejected;
    const scale: i32 = @intCast(@as(*align(1) const u32, @ptrCast(&display)).*);
    if (scale < 1 or scale > 2 or w <= 0 or h <= 0 or w > 2000 or h > 2000) return Error.Rejected;

    // The buffer is created before the request, so Peel can map it by name the
    // moment it handles the message.
    var shm_name_buf: [32]u8 = undefined;
    const shm_name = proto.shmName(&shm_name_buf, pid);

    const size: usize = @intCast(w * h * 4 * scale * scale);
    const shm = pulp.shmCreate(shm_name, size) catch return Error.NoBuffer;
    const pixels = pulp.shmMap(shm, true) catch return Error.NoBuffer;

    var req = proto.CreateWindow{
        .pid = pid,
        .width = @intCast(w),
        .height = @intCast(h),
        .x = x,
        .y = y,
        .title_len = @intCast(@min(title.len, 48)),
        .shm_name_len = @intCast(shm_name.len),
        .flags = flags,
        .scale = @intCast(scale),
        .title = undefined,
        .shm_name = undefined,
    };
    @memcpy(req.title[0..req.title_len], title[0..req.title_len]);
    @memcpy(req.shm_name[0..shm_name.len], shm_name);

    const bytes: [*]const u8 = @ptrCast(&req);
    _ = pulp.portSend(server, proto.Op.create_window, bytes[0..@sizeOf(proto.CreateWindow)]) catch {
        return Error.Rejected;
    };

    var resp: [64]u8 = undefined;
    const n = pulp.portRecv(reply, &resp, true) catch return Error.Rejected;
    if (n < @sizeOf(proto.Created)) return Error.Rejected;

    const created: *align(1) const proto.Created = @ptrCast(&resp);
    if (created.window_id == 0) return Error.Rejected;

    return .{
        .id = created.window_id,
        .width = w,
        .height = h,
        .scale = scale,
        .stride = w * scale,
        .pixels = @ptrCast(@alignCast(pixels)),
        .server = server,
        .reply = reply,
    };
}
