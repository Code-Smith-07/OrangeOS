//! The Peel display protocol.
//!
//! One port carries control; shared memory carries pixels. A client never
//! sends pixel data through the kernel — it writes into a buffer Peel has
//! mapped and then sends a 32-byte message saying which rectangle changed.
//! That split is why compositing stays cheap.
//!
//! Both Peel and its clients build against this file, so the wire format
//! cannot drift between them.

pub const PORT = "peel";

pub const WindowFlags = struct {
    pub const closable: u32 = 1 << 0;
};

pub const Op = struct {
    /// Client -> Peel: please give me a window.
    pub const create_window: u32 = 1;
    /// Client -> Peel: this rectangle of my buffer changed.
    pub const commit: u32 = 2;
    /// Client -> Peel: I am going away.
    pub const destroy: u32 = 3;
    /// Peel -> client: your window was created.
    pub const created: u32 = 128;
    /// Peel -> client: an input event landed on you.
    pub const input: u32 = 129;
    /// Peel -> client: the user pressed the window's close button.
    pub const close_requested: u32 = 130;
};

/// Request to create a window. `shm_name` names a buffer the client has
/// already created, sized width * height * 4 bytes.
pub const CreateWindow = extern struct {
    /// The client's pid, so Peel can derive its reply port name. Handle
    /// transfer would make this unnecessary; it does not exist yet.
    pid: i64,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    title_len: u32,
    shm_name_len: u32,
    flags: u32,
    title: [48]u8,
    shm_name: [32]u8,
};

/// Client says part of its buffer changed.
pub const Commit = extern struct {
    window_id: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Either side identifies the window whose lifetime is ending.
pub const Destroy = extern struct {
    window_id: u32,
};

/// Peel's answer to create_window.
pub const Created = extern struct {
    window_id: u32,
    width: u32,
    height: u32,
};

/// An input event, in window-relative coordinates.
pub const Input = extern struct {
    window_id: u32,
    kind: u8,
    code: u8,
    value: u8,
    reserved: u8,
    x: i32,
    y: i32,
};

pub fn replyPortName(buf: []u8, pid: i64) []const u8 {
    // "peel.<pid>" — each client gets its own reply port, since handle
    // transfer does not exist yet and a shared reply port would deliver one
    // client's answer to another.
    const prefix = "peel.";
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v: u64 = @intCast(if (pid < 0) 0 else pid);
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
        }
    }
    var i: usize = 0;
    while (i < d) : (i += 1) {
        buf[n] = digits[d - 1 - i];
        n += 1;
    }
    return buf[0..n];
}

pub fn shmName(buf: []u8, pid: i64) []const u8 {
    const prefix = "win.";
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;

    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v: u64 = @intCast(if (pid < 0) 0 else pid);
    if (v == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (v > 0) : (v /= 10) {
            digits[d] = '0' + @as(u8, @intCast(v % 10));
            d += 1;
        }
    }
    var i: usize = 0;
    while (i < d) : (i += 1) {
        buf[n] = digits[d - 1 - i];
        n += 1;
    }
    return buf[0..n];
}
