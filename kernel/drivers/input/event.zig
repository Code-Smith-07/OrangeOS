//! Input event queue.
//!
//! Drivers push events from interrupt context; userspace drains them through a
//! syscall. One queue for now — Peel is the only consumer and owns the screen.
//! Per-device queues arrive when there is a device manager to hand them out.

const sched = @import("../../sched/sched.zig");
const spinlock = @import("../../sync/spinlock.zig");

pub const Kind = enum(u8) {
    key = 1,
    mouse = 2,
};

/// Wire format handed to userspace. Fixed layout so Pulp can read it directly.
pub const Event = extern struct {
    kind: u8,
    /// key: scancode. mouse: button bitmask (1 left, 2 right, 4 middle).
    code: u8,
    /// key: 1 pressed, 0 released. key: bit 1 set if the scancode was extended.
    value: u8,
    reserved: u8 = 0,
    /// mouse only.
    dx: i32,
    dy: i32,
};

pub const KeyEvent = struct {
    code: u8,
    extended: bool,
    pressed: bool,
};

pub const MouseEvent = struct {
    dx: i32,
    dy: i32,
    left: bool,
    right: bool,
    middle: bool,
};

const CAPACITY = 256;

var queue: [CAPACITY]Event = undefined;
var head: usize = 0;
var tail: usize = 0;
var lock: spinlock.SpinLock = .{};

fn push(e: Event) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    const next = (head + 1) % CAPACITY;
    // Full: drop the oldest. For input, the newest state is what matters —
    // a stale mouse delta is worse than a missing one.
    if (next == tail) tail = (tail + 1) % CAPACITY;
    queue[head] = e;
    head = next;
}

/// Wait channel for "input is available". The compositor blocks here rather
/// than polling; a keystroke or mouse move wakes it directly.
pub fn waitChannel() usize {
    return @intFromPtr(&queue);
}

pub fn pushKey(k: KeyEvent) void {
    push(.{
        .kind = @intFromEnum(Kind.key),
        .code = k.code,
        .value = (if (k.pressed) @as(u8, 1) else 0) | (if (k.extended) @as(u8, 2) else 0),
        .dx = 0,
        .dy = 0,
    });
    sched.wakeChannel(waitChannel());
}

pub fn pushMouse(m: MouseEvent) void {
    push(.{
        .kind = @intFromEnum(Kind.mouse),
        .code = (if (m.left) @as(u8, 1) else 0) |
            (if (m.right) @as(u8, 2) else 0) |
            (if (m.middle) @as(u8, 4) else 0),
        .value = 0,
        .dx = m.dx,
        .dy = m.dy,
    });
    sched.wakeChannel(waitChannel());
}

/// Drain up to `out.len` events. Returns how many were taken.
pub fn drain(out: []Event) usize {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    var n: usize = 0;
    while (n < out.len and tail != head) {
        out[n] = queue[tail];
        tail = (tail + 1) % CAPACITY;
        n += 1;
    }
    return n;
}

pub fn pending() usize {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    if (head >= tail) return head - tail;
    return CAPACITY - tail + head;
}
