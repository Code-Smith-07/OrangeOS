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

const std = @import("std");
const io = @import("../arch/x86_64/io.zig");

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
};

fn interruptsEnabled() bool {
    const flags = asm volatile (
        \\ pushfq
        \\ popq %[out]
        : [out] "=r" (-> u64),
    );
    return flags & (1 << 9) != 0;
}

/// Both ends are touched from different threads, so every access runs with
/// interrupts off. The rings are small and the critical sections are a few
/// instructions; a lock would cost more than it saves.
fn critical() bool {
    const was = interruptsEnabled();
    io.cli();
    return was;
}

fn restore(was: bool) void {
    if (was) io.sti();
}

pub fn slaveWrite(p: *Pty, bytes: []const u8) usize {
    const was = critical();
    defer restore(was);
    for (bytes) |c| p.to_master.push(c);
    return bytes.len;
}

pub fn masterRead(p: *Pty, out: []u8) usize {
    const was = critical();
    defer restore(was);
    var n: usize = 0;
    while (n < out.len) {
        out[n] = p.to_master.pop() orelse break;
        n += 1;
    }
    return n;
}

pub fn masterWrite(p: *Pty, bytes: []const u8) usize {
    const was = critical();
    defer restore(was);
    for (bytes) |c| p.to_slave.push(c);
    return bytes.len;
}

pub fn slaveRead(p: *Pty, out: []u8) usize {
    const was = critical();
    defer restore(was);
    var n: usize = 0;
    while (n < out.len) {
        out[n] = p.to_slave.pop() orelse break;
        n += 1;
    }
    return n;
}

pub fn slaveHasInput(p: *Pty) bool {
    return !p.to_slave.isEmpty();
}

pub fn masterHasOutput(p: *Pty) bool {
    return !p.to_master.isEmpty();
}
