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
    /// The content size being drawn now. A resizable window changes it when
    /// Peel configures a new size; the buffer and stride stay the same.
    width: i32,
    height: i32,
    scale: i32,
    stride: i32,
    pixels: [*]u32,
    server: i64,
    reply: i64,
    /// The largest content the buffer holds (== width/height when fixed).
    capacity_w: i32 = 0,
    capacity_h: i32 = 0,
    min_w: i32 = 0,
    min_h: i32 = 0,

    /// Take a configure message: true when the size changed and the client
    /// must re-lay out, redraw everything, and then call ackResize().
    pub fn configure(self: *Window, payload: []const u8) bool {
        if (payload.len < @sizeOf(proto.Configure)) return false;
        const c: *align(1) const proto.Configure = @ptrCast(payload.ptr);
        if (c.window_id != self.id) return false;
        const w = @import("std").math.clamp(@as(i32, @intCast(@min(c.width, 4096))), @max(1, self.min_w), @max(1, self.capacity_w));
        const h = @import("std").math.clamp(@as(i32, @intCast(@min(c.height, 4096))), @max(1, self.min_h), @max(1, self.capacity_h));
        if (w == self.width and h == self.height) {
            // Still answer, so Peel does not wait for a frame that will not come.
            self.ackResize();
            return false;
        }
        self.width = w;
        self.height = h;
        return true;
    }

    /// Tell Peel the buffer now shows the current size (after redrawing).
    pub fn ackResize(self: *const Window) void {
        const msg = proto.Configure{ .window_id = self.id, .width = @intCast(self.width), .height = @intCast(self.height) };
        _ = pulp.portSend(self.server, proto.Op.resized, @import("std").mem.asBytes(&msg)) catch {};
    }

    /// The user pressed the client's own toolbar background (full-size
    /// content windows): let Peel move the window with the pointer.
    pub fn requestMove(self: *const Window) void {
        const msg = proto.Destroy{ .window_id = self.id };
        _ = pulp.portSend(self.server, proto.Op.move_request, @import("std").mem.asBytes(&msg)) catch {};
    }

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

    /// Ask Peel to open a file with the app that handles it.
    pub fn openDocument(self: *const Window, path: []const u8) void {
        _ = pulp.portSend(self.server, proto.Op.open_document, path[0..@min(path.len, 255)]) catch {};
    }

    /// Change the title bar text (the app shown in the menu bar stays).
    pub fn setTitle(self: *const Window, title: []const u8) void {
        var buf: [4 + 48]u8 = undefined;
        @memcpy(buf[0..4], @import("std").mem.asBytes(&self.id));
        const n = @min(title.len, 48);
        @memcpy(buf[4..][0..n], title[0..n]);
        _ = pulp.portSend(self.server, proto.Op.set_title, buf[0 .. 4 + n]) catch {};
    }

    /// Publish this window's menus (see proto.MENU_MAX_BYTES for the text).
    pub fn setMenu(self: *const Window, text: []const u8) void {
        var buf: [4 + proto.MENU_MAX_BYTES]u8 = undefined;
        @memcpy(buf[0..4], @import("std").mem.asBytes(&self.id));
        const n = @min(text.len, proto.MENU_MAX_BYTES);
        @memcpy(buf[4..][0..n], text[0..n]);
        _ = pulp.portSend(self.server, proto.Op.set_menu, buf[0 .. 4 + n]) catch {};
    }

    /// Show a notification banner, kept in the notification list.
    pub fn notify(self: *const Window, title: []const u8, body: []const u8) void {
        sendNotification(self.server, title, body);
    }

    pub fn setPreference(self: *const Window, key: u32, value: u32) void {
        const msg = proto.Preference{ .key = key, .value = value };
        _ = pulp.portSend(self.server, proto.Op.set_preference, @import("std").mem.asBytes(&msg)) catch {};
    }

    /// Ask for the desktop preferences; they arrive as Op.preferences.
    pub fn requestPreferences(self: *const Window) void {
        const pid = pulp.getpid();
        _ = pulp.portSend(self.server, proto.Op.get_preferences, @import("std").mem.asBytes(&pid)) catch {};
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

fn sendNotification(server: i64, title: []const u8, body: []const u8) void {
    var msg = proto.Notify{ .title_len = @intCast(@min(title.len, 48)), .body_len = @intCast(@min(body.len, 120)), .title = [_]u8{0} ** 48, .body = [_]u8{0} ** 120 };
    @memcpy(msg.title[0..msg.title_len], title[0..msg.title_len]);
    @memcpy(msg.body[0..msg.body_len], body[0..msg.body_len]);
    _ = pulp.portSend(server, proto.Op.notify, @import("std").mem.asBytes(&msg)) catch {};
}

/// A notification from a program with no window (a command-line tool).
pub fn notifyWithoutWindow(title: []const u8, body: []const u8) Error!void {
    const server = pulp.portConnect(proto.PORT) catch return Error.NoDisplayServer;
    defer pulp.handleClose(server);
    sendNotification(server, title, body);
}

/// Connect to Peel and ask for a window.
pub fn createWindow(title: []const u8, w: i32, h: i32, x: i32, y: i32) Error!Window {
    return createWindowWithFlags(title, w, h, x, y, proto.WindowFlags.closable);
}

pub fn createWindowWithFlags(title: []const u8, w: i32, h: i32, x: i32, y: i32, flags: u32) Error!Window {
    return open(.{ .title = title, .width = w, .height = h, .x = x, .y = y, .flags = flags });
}

pub const Options = struct {
    title: []const u8,
    width: i32,
    height: i32,
    x: i32 = -1,
    y: i32 = -1,
    flags: u32 = proto.WindowFlags.closable,
    /// Resizable windows: the smallest content size.
    min_w: i32 = 0,
    min_h: i32 = 0,
    /// Full-size content windows: the client's top bar height.
    bar_height: i32 = 0,
    /// Which application this is (proto.App.*).
    app: u32 = proto.App.welcome,
};

/// Connect to Peel and ask for a window. A resizable window's buffer is
/// allocated once at the largest content the screen allows, so a resize
/// never reallocates or remaps memory.
pub fn open(o: Options) Error!Window {
    const title = o.title;
    var w = o.width;
    var h = o.height;
    const x = o.x;
    const y = o.y;
    const flags = o.flags;
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
    var display: [16]u8 = undefined;
    const dn = pulp.portRecv(reply, &display, true) catch return Error.Rejected;
    if (dn < @sizeOf(proto.DisplayInfo)) return Error.Rejected;
    const info: *align(1) const proto.DisplayInfo = @ptrCast(&display);
    const scale: i32 = @intCast(info.scale);
    if (scale < 1 or scale > 2 or w <= 0 or h <= 0 or w > 2000 or h > 2000) return Error.Rejected;
    const resizable = flags & proto.WindowFlags.resizable != 0;
    var cap_w = w;
    var cap_h = h;
    if (resizable) {
        cap_w = @max(w, @as(i32, @intCast(@min(info.max_width, 2000))));
        cap_h = @max(h, @as(i32, @intCast(@min(info.max_height, 2000))));
        // The kernel caps one shared buffer at 16 MiB.
        while (@as(i64, cap_w) * cap_h * 4 * scale * scale > 16 * 1024 * 1024) cap_h -= 8;
        w = @min(w, cap_w);
        h = @min(h, cap_h);
    }

    // The buffer is created before the request, so Peel can map it by name the
    // moment it handles the message.
    var shm_name_buf: [32]u8 = undefined;
    const shm_name = proto.shmName(&shm_name_buf, pid);

    const size: usize = @intCast(cap_w * cap_h * 4 * scale * scale);
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
        .capacity_w = if (resizable) @intCast(cap_w) else 0,
        .capacity_h = if (resizable) @intCast(cap_h) else 0,
        .min_w = @intCast(@max(0, @min(o.min_w, w))),
        .min_h = @intCast(@max(0, @min(o.min_h, h))),
        .bar_height = @intCast(@max(0, o.bar_height)),
        .app = o.app,
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
        .stride = cap_w * scale,
        .pixels = @ptrCast(@alignCast(pixels)),
        .server = server,
        .reply = reply,
        .capacity_w = cap_w,
        .capacity_h = cap_h,
        .min_w = if (resizable) @max(1, @min(o.min_w, w)) else w,
        .min_h = if (resizable) @max(1, @min(o.min_h, h)) else h,
    };
}
