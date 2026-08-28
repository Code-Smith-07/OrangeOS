//! Pseudo-terminals.
//!
//! A PTY is two byte streams crossed over. The *master* is held by a terminal
//! emulator; the *slave* is what a shell sees as stdin and stdout. What the
//! shell writes appears on the master; what the master writes appears on the
//! shell's stdin.
//!
//! This is what lets Juice run inside a window without knowing it: it still
//! reads fd 0 and writes fd 1, and the kernel routes those to a PTY instead of
//! the serial port.

const sched = @import("../sched/sched.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Error = error{Full};

const CAPACITY = 4096;

const Ring = struct {
    buf: [CAPACITY]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,

    fn isEmpty(self: *const Ring) bool {
        return self.head == self.tail;
    }

    fn push(self: *Ring, c: u8) void {
        const next = (self.head + 1) % CAPACITY;
        // Full: drop the newest. Terminal output that overruns a stalled
        // reader is better truncated at the end than corrupted in the middle.
        if (next == self.tail) return;
        self.buf[self.head] = c;
        self.head = next;
    }

    fn pop(self: *Ring) ?u8 {
        if (self.isEmpty()) return null;
        const c = self.buf[self.tail];
        self.tail = (self.tail + 1) % CAPACITY;
        return c;
    }
};

pub const Pty = struct {
    /// Written by the slave (the shell), read by the master (the terminal).
    to_master: Ring = .{},
    /// Written by the master (keystrokes), read by the slave.
    to_slave: Ring = .{},
    /// Terminal geometry, so a program could size its output. Unused so far.
    cols: u16 = 80,
    rows: u16 = 24,
    lock: spinlock.SpinLock = .{},
};

pub fn slaveWrite(p: *Pty, bytes: []const u8) usize {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    for (bytes) |c| p.to_master.push(c);
    return bytes.len;
}

pub fn masterRead(p: *Pty, out: []u8) usize {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    var n: usize = 0;
    while (n < out.len) {
        out[n] = p.to_master.pop() orelse break;
        n += 1;
    }
    return n;
}

/// Wait channel for a thread blocked reading this PTY's slave end.
pub fn waitChannel(p: *Pty) usize {
    return @intFromPtr(p);
}

pub fn masterWrite(p: *Pty, bytes: []const u8) usize {
    {
        const state = spinlock.acquireIrqSave(&p.lock);
        defer spinlock.releaseIrqRestore(&p.lock, state);
        for (bytes) |c| p.to_slave.push(c);
    }

    // Outside the critical section: the slave has input now.
    sched.wakeChannel(waitChannel(p));
    return bytes.len;
}

pub fn slaveRead(p: *Pty, out: []u8) usize {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    var n: usize = 0;
    while (n < out.len) {
        out[n] = p.to_slave.pop() orelse break;
        n += 1;
    }
    return n;
}

pub fn slaveHasInput(p: *Pty) bool {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    return !p.to_slave.isEmpty();
}

pub fn masterHasOutput(p: *Pty) bool {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    return !p.to_master.isEmpty();
}
