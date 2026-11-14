//! A small application framework for native OrangeOS apps (docs/design/014,
//! M3 onwards): one window, a private staging buffer, and Peel's messages
//! turned into events. An app's whole loop is:
//!
//!     var app = App.open(.{ ... });
//!     while (true) {
//!         while (app.next()) |event| switch (event) { ... };
//!         if (dirty) { paint(app.surface()); app.presentAll(); }
//!         app.idle();
//!     }
//!
//! Resizing: `next()` returns `.resized` once the window has its new size;
//! the app repaints everything and `presentAll()` tells Peel the frame is
//! ready. Nothing else is needed for edge drags, zoom or tiling.
const std = @import("std");
const pulp = @import("pulp");
const libpeel = @import("libpeel");
const keymap = @import("keymap");
pub const ui = @import("ui");
pub const image = @import("image");
pub const proto = libpeel.proto;

pub const Options = struct {
    title: []const u8,
    app: u32,
    width: i32,
    height: i32,
    x: i32 = -1,
    y: i32 = -1,
    resizable: bool = true,
    min_w: i32 = 320,
    min_h: i32 = 240,
    /// Draw under the window buttons, with a top bar this tall (0: Peel
    /// draws an ordinary title bar).
    bar_height: i32 = 0,
    /// The close button asks first (`.close` arrives and the window stays).
    confirms_close: bool = false,
    /// The app's menus for the menu bar (proto.MENU_MAX_BYTES format).
    menu: []const u8 = "",
};

pub const Key = struct {
    /// Set-1 scancode; `extended` tells the arrow keys from the keypad.
    code: u8,
    extended: bool,
    down: bool,
    /// The printable character, or 0.
    ch: u8,
    ctrl: bool,
    shift: bool,
    alt: bool,
};

pub const Mouse = struct {
    x: i32,
    y: i32,
    buttons: u8,
    /// The left button went down or up with this event.
    pressed: bool,
    released: bool,
    /// The press is the second of a double click.
    double: bool,
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    /// Wheel steps, positive towards the user (scroll down).
    wheel: i32,
    resized,
    close,
    menu: u32,
    open_file: []const u8,
    preferences: proto.Preferences,
};

// Scancodes apps use by name.
pub const K = struct {
    pub const esc: u8 = 0x01;
    pub const backspace: u8 = 0x0E;
    pub const tab: u8 = 0x0F;
    pub const enter: u8 = 0x1C;
    pub const space: u8 = 0x39;
    pub const f2: u8 = 0x3C;
    pub const home: u8 = 0x47;
    pub const up: u8 = 0x48;
    pub const page_up: u8 = 0x49;
    pub const left: u8 = 0x4B;
    pub const right: u8 = 0x4D;
    pub const end: u8 = 0x4F;
    pub const down: u8 = 0x50;
    pub const page_down: u8 = 0x51;
    pub const delete: u8 = 0x53;
};

pub const App = struct {
    win: libpeel.Window,
    staging: []u32,
    pointer: ui.Pointer = .{},
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    buttons: u8 = 0,
    last_press_ms: u64 = 0,
    last_press_x: i32 = -100,
    last_press_y: i32 = -100,
    pending_ack: bool = false,
    path_buf: [256]u8 = undefined,
    msg: [1280]u8 = undefined,

    pub fn open(o: Options) App {
        const F = proto.WindowFlags;
        var flags = F.closable;
        if (o.resizable) flags |= F.resizable;
        if (o.bar_height > 0) flags |= F.full_size_content;
        if (o.confirms_close) flags |= F.confirms_close;
        const win = libpeel.open(.{
            .title = o.title,
            .width = o.width,
            .height = o.height,
            .x = o.x,
            .y = o.y,
            .flags = flags,
            .min_w = o.min_w,
            .min_h = o.min_h,
            .bar_height = o.bar_height,
            .app = o.app,
        }) catch pulp.exit(1);
        const bytes: usize = @intCast(win.stride * win.capacity_h * win.scale * 4);
        const memory = pulp.mapMemory(bytes, .read_write) catch pulp.exit(1);
        var app = App{ .win = win, .staging = @as([*]u32, @ptrCast(memory.ptr))[0 .. bytes / 4] };
        if (o.menu.len > 0) app.win.setMenu(o.menu);
        return app;
    }

    pub fn width(self: *const App) i32 {
        return self.win.width;
    }
    pub fn height(self: *const App) i32 {
        return self.win.height;
    }

    /// A surface over the private staging buffer, clipped to the window.
    pub fn surface(self: *App) ui.Surface {
        var s = ui.surface(&self.win);
        s.pixels = self.staging.ptr;
        s.setClip(.{ .x = 0, .y = 0, .w = self.win.width, .h = self.win.height });
        return s;
    }

    /// Show a finished rectangle of the staging buffer.
    pub fn present(self: *App, r: ui.Rect) void {
        ui.publishRegion(&self.win, self.staging, r);
    }

    /// Show the whole window; after a resize this is also the answer Peel
    /// is waiting for.
    pub fn presentAll(self: *App) void {
        self.present(.{ .x = 0, .y = 0, .w = self.win.width, .h = self.win.height });
        if (self.pending_ack) {
            self.pending_ack = false;
            self.win.ackResize();
        }
    }

    /// Sleep one frame when there is nothing to do.
    pub fn idle(_: *App) void {
        pulp.sleepMs(16);
    }

    pub fn quit(self: *App) noreturn {
        self.win.destroy();
        pulp.exit(0);
    }

    /// Update the shared pointer state against the app's click targets;
    /// returns the id of a target that was clicked (pressed and released).
    pub fn click(self: *App, m: Mouse, targets: []const ui.Button) u32 {
        return self.pointer.update(m.x, m.y, m.buttons, targets);
    }

    /// The next event, or null when none is waiting.
    pub fn next(self: *App) ?Event {
        while (true) {
            const m = pulp.portRecvMsg(self.win.reply, &self.msg, false) catch return null;
            if (m.len == 0 and m.opcode == 0) return null;
            switch (m.opcode) {
                proto.Op.close_requested => return .close,
                proto.Op.configure => {
                    if (self.win.configure(self.msg[0..m.len])) {
                        self.pending_ack = true;
                        return .resized;
                    }
                },
                proto.Op.menu_action => if (m.len >= 4) return .{ .menu = std.mem.readInt(u32, self.msg[0..4], .little) },
                proto.Op.open_file => {
                    const n = @min(m.len, self.path_buf.len);
                    @memcpy(self.path_buf[0..n], self.msg[0..n]);
                    return .{ .open_file = self.path_buf[0..n] };
                },
                proto.Op.preferences => if (m.len >= @sizeOf(proto.Preferences)) {
                    return .{ .preferences = @as(*align(1) const proto.Preferences, @ptrCast(&self.msg)).* };
                },
                proto.Op.input => if (m.len >= @sizeOf(proto.Input)) {
                    const ev: *align(1) const proto.Input = @ptrCast(&self.msg);
                    if (self.input(ev.*)) |event| return event;
                },
                else => {},
            }
        }
    }

    fn input(self: *App, ev: proto.Input) ?Event {
        if (ev.kind == pulp.EV_KEY) {
            const down = ev.value & 1 != 0;
            const extended = ev.value & 2 != 0;
            switch (ev.code) {
                keymap.CTRL => self.ctrl = down,
                keymap.LSHIFT, keymap.RSHIFT => if (!extended) {
                    self.shift = down;
                },
                0x38 => self.alt = down,
                else => {},
            }
            // Extended keys (arrows, Home, Delete) have no character; the
            // same codes without the E0 flag are the number pad.
            const ch: u8 = if (extended or self.ctrl or self.alt) 0 else keymap.translate(ev.code, self.shift);
            return .{ .key = .{ .code = ev.code, .extended = extended, .down = down, .ch = if (ch >= 32 and ch < 127) ch else 0, .ctrl = self.ctrl, .shift = self.shift, .alt = self.alt } };
        }
        if (ev.kind == pulp.EV_MOUSE) {
            const was = self.buttons & 1 != 0;
            const is = ev.code & 1 != 0;
            self.buttons = ev.code;
            var double = false;
            if (is and !was) {
                const now = pulp.uptimeMs();
                double = now -| self.last_press_ms <= 450 and @abs(ev.x - self.last_press_x) <= 4 and @abs(ev.y - self.last_press_y) <= 4;
                self.last_press_ms = if (double) 0 else now;
                self.last_press_x = ev.x;
                self.last_press_y = ev.y;
            }
            return .{ .mouse = .{ .x = ev.x, .y = ev.y, .buttons = ev.code, .pressed = is and !was, .released = was and !is, .double = double } };
        }
        if (ev.kind == pulp.EV_WHEEL) return .{ .wheel = @as(i8, @bitCast(ev.code)) };
        return null;
    }
};

// ── Files on /data ─────────────────────────────────────────────────────────

/// Read a whole file into `buf`; the bytes read, or null when it cannot be
/// read. `truncated` is set when the file is larger than the buffer.
pub fn readFile(path: []const u8, buf: []u8, truncated: ?*bool) ?[]u8 {
    const fd = pulp.open(path) catch return null;
    defer pulp.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = pulp.read(@intCast(fd), buf[len..@min(len + 4096, buf.len)]) catch return null;
        if (n == 0) break;
        len += n;
    }
    if (truncated) |t| {
        var extra: [1]u8 = undefined;
        t.* = len == buf.len and (pulp.read(@intCast(fd), &extra) catch 0) != 0;
    }
    return buf[0..len];
}

/// Replace `path` with `bytes` safely: write a temporary file beside it,
/// make it durable, then rename it over the original. A crash leaves either
/// the old file or the new one, never half of each.
pub fn writeFileAtomic(path: []const u8, bytes: []const u8) bool {
    var tmp_buf: [280]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.saving", .{path}) catch return false;
    const fd = pulp.openWith(tmp, pulp.OPEN_WRITE | pulp.OPEN_CREATE | pulp.OPEN_TRUNCATE) catch return false;
    var done: usize = 0;
    while (done < bytes.len) {
        const n = pulp.write(@intCast(fd), bytes[done..@min(done + 4096, bytes.len)]) catch {
            pulp.close(fd);
            pulp.unlink(tmp) catch {};
            return false;
        };
        if (n == 0) break;
        done += n;
    }
    pulp.fsSync(fd) catch {};
    pulp.close(fd);
    if (done != bytes.len) {
        pulp.unlink(tmp) catch {};
        return false;
    }
    pulp.rename(tmp, path) catch {
        pulp.unlink(tmp) catch {};
        return false;
    };
    return true;
}

/// The last component of a path.
pub fn basename(path: []const u8) []const u8 {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[cut + 1 ..];
}

// ── Pictures ───────────────────────────────────────────────────────────────

/// A picture held in memory the app got from the system: the file's bytes
/// are read, decoded, and everything is released together.
pub const Picture = struct {
    memory: []align(4096) u8,
    img: image.Image,

    pub const LoadError = error{ NotFound, TooLarge, Unsupported, Corrupt, OutOfMemory };

    /// Read and decode `path`. Transparent parts are blended over `background`.
    pub fn load(path: []const u8, background: u32) LoadError!Picture {
        const st = pulp.stat(path) catch return error.NotFound;
        if (st.size == 0) return error.Corrupt;
        if (st.size > 48 * 1024 * 1024) return error.TooLarge;
        const size: usize = @intCast(st.size);
        // The header says how much room the pixels need.
        var head: [64]u8 = undefined;
        const fd = pulp.open(path) catch return error.NotFound;
        defer pulp.close(fd);
        const got = pulp.read(@intCast(fd), &head) catch return error.NotFound;
        const info = image.probe(head[0..got]) catch |e| return switch (e) {
            error.TooLarge => error.TooLarge,
            error.Unsupported => error.Unsupported,
            else => error.Corrupt,
        };
        const pixels: usize = @as(usize, info.width) * info.height * 4;
        const work: usize = if (info.format == .png) @as(usize, info.height) * (@as(usize, info.width) * 8 + 1) + size else 0;
        const memory = pulp.mapMemory(size + pixels + work + 256 * 1024, .read_write) catch return error.OutOfMemory;
        errdefer pulp.unmapMemory(memory) catch {};
        const bytes = memory[0..size];
        @memcpy(bytes[0..got], head[0..got]);
        var len: usize = got;
        while (len < size) {
            const n = pulp.read(@intCast(fd), bytes[len..@min(len + 4096, size)]) catch return error.Corrupt;
            if (n == 0) break;
            len += n;
        }
        var fba = std.heap.FixedBufferAllocator.init(memory[size..]);
        const img = image.decode(bytes[0..len], fba.allocator(), background) catch |e| return switch (e) {
            error.TooLarge => error.TooLarge,
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
        return .{ .memory = memory, .img = img };
    }

    pub fn unload(self: *Picture) void {
        pulp.unmapMemory(self.memory) catch {};
        self.img.pixels = &.{};
    }

    pub fn problem(e: LoadError) []const u8 {
        return switch (e) {
            error.NotFound => "The file could not be read.",
            error.TooLarge => "This picture is too large to open.",
            error.Unsupported => "This kind of picture is not supported yet.",
            error.Corrupt => "The picture file is damaged.",
            error.OutOfMemory => "There is not enough memory for this picture.",
        };
    }
};

/// Draw `img` into `dest`, scaled. Enlarging blends between pixels;
/// shrinking averages the pixels each screen pixel covers, so detail does
/// not shimmer. Only the surface's clip is touched.
pub fn drawImage(s: *const ui.Surface, img: *const image.Image, dest: ui.Rect) void {
    if (dest.w <= 0 or dest.h <= 0 or img.pixels.len == 0) return;
    const area = ui.Rect.intersect(ui.Rect.intersect(dest, s.clip), .{ .x = 0, .y = 0, .w = s.width, .h = s.height });
    if (area.isEmpty()) return;
    const sc = s.scale;
    const dw: i64 = @as(i64, dest.w) * sc;
    const dh: i64 = @as(i64, dest.h) * sc;
    // Source pixels per screen pixel, 24.8 fixed point.
    const step_x: i64 = @divTrunc(@as(i64, img.width) * 256, dw);
    const step_y: i64 = @divTrunc(@as(i64, img.height) * 256, dh);
    const taps_x: i64 = std.math.clamp(@divTrunc(step_x + 255, 256), 1, 4);
    const taps_y: i64 = std.math.clamp(@divTrunc(step_y + 255, 256), 1, 4);
    var y: i32 = area.y * sc;
    while (y < area.bottom() * sc) : (y += 1) {
        const sy0: i64 = @as(i64, y - dest.y * sc) * step_y;
        var x: i32 = area.x * sc;
        while (x < area.right() * sc) : (x += 1) {
            const sx0: i64 = @as(i64, x - dest.x * sc) * step_x;
            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var ty: i64 = 0;
            while (ty < taps_y) : (ty += 1) {
                var tx: i64 = 0;
                while (tx < taps_x) : (tx += 1) {
                    // Tap centres spread evenly over the pixel's footprint.
                    const fx = sx0 + @divTrunc(step_x * (2 * tx + 1), 2 * taps_x) - 128;
                    const fy = sy0 + @divTrunc(step_y * (2 * ty + 1), 2 * taps_y) - 128;
                    const c = image.sample(img, fx, fy);
                    r += (c >> 16) & 255;
                    g += (c >> 8) & 255;
                    b += c & 255;
                }
            }
            const n: u32 = @intCast(taps_x * taps_y);
            s.pixels[@intCast(y * s.stride + x)] = ((r / n) << 16) | ((g / n) << 8) | (b / n);
        }
    }
}
