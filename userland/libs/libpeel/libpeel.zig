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
    pixels: [*]u32,
    server: i64,
    reply: i64,

    /// Direct access to the window's pixels. Writing here is not visible until
    /// commit() tells Peel which part changed.
    pub inline fn put(self: *const Window, x: i32, y: i32, color: u32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.pixels[@intCast(y * self.width + x)] = color;
    }

    pub fn fill(self: *const Window, x: i32, y: i32, w: i32, h: i32, color: u32) void {
        var yy = @max(y, 0);
        const y1 = @min(y + h, self.height);
        const x0 = @max(x, 0);
        const x1 = @min(x + w, self.width);
        while (yy < y1) : (yy += 1) {
            var xx = x0;
            while (xx < x1) : (xx += 1) {
                self.pixels[@intCast(yy * self.width + xx)] = color;
            }
        }
    }

    pub fn clear(self: *const Window, color: u32) void {
        self.fill(0, 0, self.width, self.height, color);
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
};

/// Connect to Peel and ask for a window.
pub fn createWindow(title: []const u8, w: i32, h: i32, x: i32, y: i32) Error!Window {
    const server = pulp.portConnect(proto.PORT) catch return Error.NoDisplayServer;

    const pid = pulp.getpid();

    var reply_name_buf: [32]u8 = undefined;
    const reply_name = proto.replyPortName(&reply_name_buf, pid);
    const reply = pulp.portCreate(reply_name) catch return Error.NoDisplayServer;

    // The buffer is created before the request, so Peel can map it by name the
    // moment it handles the message.
    var shm_name_buf: [32]u8 = undefined;
    const shm_name = proto.shmName(&shm_name_buf, pid);

    const size: usize = @intCast(w * h * 4);
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

    return .{
        .id = created.window_id,
        .width = w,
        .height = h,
        .pixels = @ptrCast(@alignCast(pixels)),
        .server = server,
        .reply = reply,
    };
}
