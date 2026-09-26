//! eventfd: a 64-bit counter used as a wakeup signal.
//!
//! A write adds its 8-byte value; a read returns the counter and resets it to
//! zero, or in semaphore mode returns 1 and decrements it. Reads block while
//! the counter is zero; writes block while adding would exceed 2^64 - 2. Like
//! pipes, waiters register before checking, and an exiting program leaves the
//! wait.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");
const readiness = @import("readiness.zig");

pub const Error = error{ WouldBlock, Interrupted, InvalidArgument, OutOfMemory };

const MAX: u64 = std.math.maxInt(u64) - 1;

pub const EventFd = struct {
    lock: spinlock.SpinLock = .{},
    count: u64,
    semaphore: bool,
    source: readiness.Source = .{},

    fn channel(self: *const EventFd) usize {
        return @intFromPtr(self);
    }
};

pub fn create(initial: u32, semaphore: bool) Error!*EventFd {
    const e = heap.create(EventFd) catch return Error.OutOfMemory;
    e.* = .{ .count = initial, .semaphore = semaphore };
    return e;
}

pub fn destroy(e: *EventFd) void {
    readiness.detachAll(&e.source);
    heap.destroy(e);
}

fn changed(e: *EventFd) void {
    sched.wakeChannel(e.channel());
    readiness.notify(&e.source);
}

pub fn read(e: *EventFd, buf: []u8, nonblock: bool) Error!usize {
    if (buf.len < 8) return Error.InvalidArgument;
    while (true) {
        sched.prepareWait(e.channel());
        const state = spinlock.acquireIrqSave(&e.lock);
        if (e.count > 0) {
            const value: u64 = if (e.semaphore) 1 else e.count;
            e.count -= value;
            spinlock.releaseIrqRestore(&e.lock, state);
            sched.cancelWait();
            std.mem.writeInt(u64, buf[0..8], value, .little);
            changed(e);
            return 8;
        }
        spinlock.releaseIrqRestore(&e.lock, state);
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

pub fn write(e: *EventFd, data: []const u8, nonblock: bool) Error!usize {
    if (data.len < 8) return Error.InvalidArgument;
    const value = std.mem.readInt(u64, data[0..8], .little);
    if (value == std.math.maxInt(u64)) return Error.InvalidArgument;
    while (true) {
        sched.prepareWait(e.channel());
        const state = spinlock.acquireIrqSave(&e.lock);
        if (MAX - e.count >= value) {
            e.count += value;
            spinlock.releaseIrqRestore(&e.lock, state);
            sched.cancelWait();
            changed(e);
            return 8;
        }
        spinlock.releaseIrqRestore(&e.lock, state);
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

pub const Ready = struct { readable: bool, writable: bool };

pub fn poll(e: *EventFd) Ready {
    const state = spinlock.acquireIrqSave(&e.lock);
    defer spinlock.releaseIrqRestore(&e.lock, state);
    return .{ .readable = e.count > 0, .writable = e.count < MAX };
}
