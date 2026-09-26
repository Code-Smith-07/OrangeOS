//! Pipes: a 64 KiB ring buffer from writers to readers.
//!
//! Reads return what is available, block while the pipe is empty and a
//! writer remains, and return 0 (end of file) once every write end is closed.
//! Writes block while the pipe is full; writes of up to ATOMIC_WRITE bytes go
//! in whole, never interleaved with another writer's. Writing with no reader
//! left fails with BrokenPipe (there are no signals, so no SIGPIPE).
//!
//! Waiters register on the pipe's channel before looking at its state, so a
//! change landing between the check and the sleep wakes them instead of being
//! lost. A program that is exiting abandons the wait (Interrupted).

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");
const readiness = @import("readiness.zig");

pub const CAPACITY = 64 * 1024;
/// POSIX PIPE_BUF: writes up to this size are atomic.
pub const ATOMIC_WRITE = 4096;

pub const Error = error{ WouldBlock, BrokenPipe, Interrupted, OutOfMemory };

pub const Pipe = struct {
    lock: spinlock.SpinLock = .{},
    buffer: [*]u8,
    head: usize = 0,
    len: usize = 0,
    readers: u32 = 1,
    writers: u32 = 1,
    /// Readiness watchers (epoll) of the read end [0] and the write end [1].
    /// Each end has exactly one open file description, so an end's watchers
    /// go away when that end is closed, even while the pipe lives on.
    sources: [2]readiness.Source = .{ .{}, .{} },

    fn channel(self: *const Pipe) usize {
        return @intFromPtr(self);
    }
};

pub fn create() Error!*Pipe {
    const p = heap.create(Pipe) catch return Error.OutOfMemory;
    const buffer = heap.alloc(CAPACITY) catch {
        heap.destroy(p);
        return Error.OutOfMemory;
    };
    p.* = .{ .buffer = buffer };
    return p;
}

pub fn source(p: *Pipe, writer: bool) *readiness.Source {
    return &p.sources[@intFromBool(writer)];
}

fn changed(p: *Pipe) void {
    sched.wakeChannel(p.channel());
    readiness.notify(&p.sources[0]);
    readiness.notify(&p.sources[1]);
}

pub fn read(p: *Pipe, buf: []u8, nonblock: bool) Error!usize {
    if (buf.len == 0) return 0;
    while (true) {
        sched.prepareWait(p.channel());
        const state = spinlock.acquireIrqSave(&p.lock);
        if (p.len > 0) {
            const count = @min(buf.len, p.len);
            const first = @min(count, CAPACITY - p.head);
            @memcpy(buf[0..first], p.buffer[p.head .. p.head + first]);
            @memcpy(buf[first..count], p.buffer[0 .. count - first]);
            p.head = (p.head + count) % CAPACITY;
            p.len -= count;
            spinlock.releaseIrqRestore(&p.lock, state);
            sched.cancelWait();
            changed(p);
            return count;
        }
        const writers = p.writers;
        spinlock.releaseIrqRestore(&p.lock, state);
        if (writers == 0) {
            sched.cancelWait();
            return 0;
        }
        if (nonblock) {
            sched.cancelWait();
            return Error.WouldBlock;
        }
        if (sched.interruptPending()) {
            sched.cancelWait();
            return Error.Interrupted;
        }
        sched.commitWait();
    }
}

pub fn write(p: *Pipe, data: []const u8, nonblock: bool) Error!usize {
    if (data.len == 0) return 0;
    var done: usize = 0;
    while (true) {
        sched.prepareWait(p.channel());
        const state = spinlock.acquireIrqSave(&p.lock);
        if (p.readers == 0) {
            spinlock.releaseIrqRestore(&p.lock, state);
            sched.cancelWait();
            return if (done > 0) done else Error.BrokenPipe;
        }
        const space = CAPACITY - p.len;
        const remaining = data.len - done;
        // A small write waits for room for all of it, so it is never split.
        const needed = if (data.len <= ATOMIC_WRITE) remaining else 1;
        if (space >= needed) {
            const count = @min(space, remaining);
            const tail = (p.head + p.len) % CAPACITY;
            const first = @min(count, CAPACITY - tail);
            @memcpy(p.buffer[tail .. tail + first], data[done .. done + first]);
            @memcpy(p.buffer[0 .. count - first], data[done + first .. done + count]);
            p.len += count;
            done += count;
            spinlock.releaseIrqRestore(&p.lock, state);
            sched.cancelWait();
            changed(p);
            if (done == data.len) return done;
            continue;
        }
        spinlock.releaseIrqRestore(&p.lock, state);
        if (nonblock) {
            sched.cancelWait();
            return if (done > 0) done else Error.WouldBlock;
        }
        if (sched.interruptPending()) {
            sched.cancelWait();
            return if (done > 0) done else Error.Interrupted;
        }
        sched.commitWait();
    }
}

pub const Ready = struct { readable: bool, writable: bool, hangup: bool, peer_closed: bool };

/// Level-triggered state for readiness queries.
pub fn poll(p: *Pipe) Ready {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    return .{
        .readable = p.len > 0 or p.writers == 0,
        .writable = p.readers > 0 and CAPACITY - p.len >= ATOMIC_WRITE,
        // For the read end: no writer left. For the write end: no reader.
        .hangup = p.writers == 0,
        .peer_closed = p.readers == 0,
    };
}

pub fn bytesAvailable(p: *Pipe) usize {
    const state = spinlock.acquireIrqSave(&p.lock);
    defer spinlock.releaseIrqRestore(&p.lock, state);
    return p.len;
}

/// Close one end. The last close of both frees the pipe.
pub fn closeEnd(p: *Pipe, writer: bool) void {
    readiness.detachAll(source(p, writer));
    const state = spinlock.acquireIrqSave(&p.lock);
    if (writer) p.writers -= 1 else p.readers -= 1;
    const gone = p.readers == 0 and p.writers == 0;
    spinlock.releaseIrqRestore(&p.lock, state);
    changed(p);
    if (gone) {
        heap.free(p.buffer);
        heap.destroy(p);
    }
}
