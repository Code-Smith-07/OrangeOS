//! epoll and poll: waiting for any of several descriptors to become ready.
//!
//! An epoll instance holds interests, one per (descriptor number, open file
//! description) pair. Each interest is a readiness watcher on its
//! description's object. A notification marks the interest pending and wakes
//! the instance's waiters; `wait` then queries the actual state of every
//! interest. That gives level-triggered reporting by default. EPOLLET
//! reports only interests notified since their last report, and
//! EPOLLONESHOT disables an interest after one report until EPOLL_CTL_MOD.
//!
//! Interests hold no reference on their description. When the description
//! closes (every descriptor for it closed), the readiness layer detaches the
//! watcher and the interest is dropped at the next pass, as Linux removes a
//! closed file from epoll sets.
//!
//! poll() uses the same watchers for the duration of one call, holding a
//! reference on each description meanwhile.
//!
//! Lock order: epoll instance -> readiness -> scheduler.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");
const time = @import("../time/time.zig");
const readiness = @import("readiness.zig");
const fd = @import("../fs/fd.zig");

pub const IN: u32 = 0x001;
pub const PRI: u32 = 0x002;
pub const OUT: u32 = 0x004;
pub const ERR: u32 = 0x008;
pub const HUP: u32 = 0x010;
pub const NVAL: u32 = 0x020;
pub const RDNORM: u32 = 0x040;
pub const WRNORM: u32 = 0x100;
pub const RDHUP: u32 = 0x2000;
pub const ONESHOT: u32 = 1 << 30;
pub const ET: u32 = 1 << 31;
/// Conditions reported whether or not they were asked for.
const ALWAYS: u32 = ERR | HUP;
/// Event bits an interest may ask for.
const REQUESTABLE: u32 = IN | PRI | OUT | ERR | HUP | RDNORM | WRNORM | RDHUP | ONESHOT | ET;

pub const Error = error{ BadFd, Exists, NotFound, NotPermitted, InvalidArgument, OutOfMemory, Interrupted };

pub const Event = struct { events: u32, data: u64 };

const Interest = struct {
    watcher: readiness.Watcher = .{ .notify = notifyInterest },
    epoll: *Epoll,
    number: i32,
    /// Valid while `watcher.source` is set (under the readiness lock).
    desc: *fd.Description,
    events: u32,
    data: u64,
    /// Notified since last reported; guarded by the readiness lock.
    pending: bool = true,
    /// A oneshot interest that has reported; guarded by the epoll lock.
    disabled: bool = false,
    next: ?*Interest = null,
};

pub const Epoll = struct {
    lock: spinlock.SpinLock = .{},
    interests: ?*Interest = null,

    fn channel(self: *const Epoll) usize {
        return @intFromPtr(self);
    }
};

fn notifyInterest(watcher: *readiness.Watcher) void {
    const interest: *Interest = @fieldParentPtr("watcher", watcher);
    interest.pending = true;
    sched.wakeChannel(interest.epoll.channel());
}

pub fn create() Error!*Epoll {
    const ep = heap.create(Epoll) catch return Error.OutOfMemory;
    ep.* = .{};
    return ep;
}

/// The instance's description closed: drop every interest.
pub fn destroy(ep: *Epoll) void {
    var cursor = ep.interests;
    while (cursor) |interest| {
        cursor = interest.next;
        const state = readiness.acquire();
        readiness.detachLocked(&interest.watcher);
        readiness.releaseLock(state);
        heap.destroy(interest);
    }
    heap.destroy(ep);
}

/// Caller holds the epoll lock. Unlinks and frees interests whose
/// description has closed.
fn reapLocked(ep: *Epoll) void {
    var link = &ep.interests;
    while (link.*) |interest| {
        const state = readiness.acquire();
        const dead = interest.watcher.source == null;
        readiness.releaseLock(state);
        if (dead) {
            link.* = interest.next;
            heap.destroy(interest);
        } else link = &interest.next;
    }
}

/// Caller holds the epoll lock.
fn findLocked(ep: *Epoll, number: i32, desc: *fd.Description) ?*Interest {
    var cursor = ep.interests;
    while (cursor) |interest| : (cursor = interest.next) {
        if (interest.number == number and interest.desc == desc and interest.watcher.source != null) return interest;
    }
    return null;
}

pub const Op = enum(u32) { add = 1, del = 2, mod = 3 };

/// EPOLL_CTL_*. `desc` is the target descriptor's description, referenced by
/// the caller for the duration of the call.
pub fn control(ep: *Epoll, op: Op, number: i32, desc: *fd.Description, event: Event) Error!void {
    if (event.events & ~REQUESTABLE != 0 and op != .del) return Error.InvalidArgument;
    const source = desc.source() orelse return Error.NotPermitted; // regular files, as on Linux
    const state = spinlock.acquireIrqSave(&ep.lock);
    defer spinlock.releaseIrqRestore(&ep.lock, state);
    reapLocked(ep);
    const existing = findLocked(ep, number, desc);
    switch (op) {
        .add => {
            if (existing != null) return Error.Exists;
            const interest = heap.create(Interest) catch return Error.OutOfMemory;
            interest.* = .{ .epoll = ep, .number = number, .desc = desc, .events = event.events, .data = event.data, .next = ep.interests };
            const r = readiness.acquire();
            readiness.attachLocked(source, &interest.watcher);
            readiness.releaseLock(r);
            ep.interests = interest;
        },
        .mod => {
            const interest = existing orelse return Error.NotFound;
            const r = readiness.acquire();
            interest.events = event.events;
            interest.data = event.data;
            interest.pending = true;
            readiness.releaseLock(r);
            interest.disabled = false;
        },
        .del => {
            const interest = existing orelse return Error.NotFound;
            const r = readiness.acquire();
            readiness.detachLocked(&interest.watcher);
            readiness.releaseLock(r);
            reapLocked(ep);
        },
    }
    sched.wakeChannel(ep.channel());
}

/// Collect up to `out.len` ready interests. Caller holds the epoll lock.
fn scanLocked(ep: *Epoll, out: []Event) usize {
    var count: usize = 0;
    var cursor = ep.interests;
    while (cursor) |interest| : (cursor = interest.next) {
        if (count == out.len) break;
        if (interest.disabled) continue;
        // Pin the description; it may be closing on another CPU.
        const r = readiness.acquire();
        const alive = interest.watcher.source != null and interest.desc.tryRetain();
        const pending = interest.pending;
        readiness.releaseLock(r);
        if (!alive) continue;
        const ready = fd.readinessOf(interest.desc) & (interest.events | ALWAYS);
        interest.desc.release();
        if (ready == 0) continue;
        if (interest.events & ET != 0) {
            if (!pending) continue;
            const again = readiness.acquire();
            interest.pending = false;
            readiness.releaseLock(again);
        }
        if (interest.events & ONESHOT != 0) interest.disabled = true;
        out[count] = .{ .events = ready, .data = interest.data };
        count += 1;
    }
    return count;
}

/// Milliseconds left before `deadline`, at least 1; null once it passed.
fn remaining(deadline: u64) ?u64 {
    const now = time.monotonicNs();
    if (now >= deadline) return null;
    return @max((deadline - now + 999_999) / 1_000_000, 1);
}

/// epoll_wait: `timeout_ms` < 0 waits indefinitely, 0 only checks. Call with
/// interrupts enabled.
pub fn wait(ep: *Epoll, out: []Event, timeout_ms: i64) Error!usize {
    const deadline: ?u64 = if (timeout_ms > 0) time.monotonicNs() + @as(u64, @intCast(timeout_ms)) * 1_000_000 else null;
    while (true) {
        sched.prepareWait(ep.channel());
        const count = blk: {
            const state = spinlock.acquireIrqSave(&ep.lock);
            defer spinlock.releaseIrqRestore(&ep.lock, state);
            reapLocked(ep);
            break :blk scanLocked(ep, out);
        };
        if (count > 0 or timeout_ms == 0) {
            sched.cancelWait();
            return count;
        }
        if (sched.interruptPending()) {
            sched.cancelWait();
            return Error.Interrupted;
        }
        if (deadline) |d| {
            const ms = remaining(d) orelse {
                sched.cancelWait();
                return 0;
            };
            sched.commitWaitTimeout(ms);
        } else sched.commitWait();
    }
}

// ── poll() ──────────────────────────────────────────────────────────────────

pub const PollEntry = struct {
    number: i32,
    requested: u32,
    returned: u32 = 0,
    /// Referenced for the duration of the call; null for a bad descriptor or
    /// the console.
    desc: ?*fd.Description = null,
    watcher: readiness.Watcher = .{ .notify = notifyPoll },
    channel: usize = 0,
};

fn notifyPoll(watcher: *readiness.Watcher) void {
    const entry: *PollEntry = @fieldParentPtr("watcher", watcher);
    sched.wakeChannel(entry.channel);
}

/// poll(): fill `returned` for every entry and return how many are nonzero.
/// Negative descriptor numbers are ignored, as POSIX specifies. Call with
/// interrupts enabled.
pub fn poll(table: *fd.FileTable, entries: []PollEntry, timeout_ms: i64) Error!usize {
    var channel_anchor: u8 = 0;
    const channel = @intFromPtr(&channel_anchor);
    for (entries) |*entry| {
        entry.channel = channel;
        if (entry.number < 0) continue;
        entry.desc = fd.lookup(table, entry.number);
        const desc = entry.desc orelse continue;
        if (desc.source()) |source| {
            const r = readiness.acquire();
            readiness.attachLocked(source, &entry.watcher);
            readiness.releaseLock(r);
        }
    }
    defer for (entries) |*entry| {
        const desc = entry.desc orelse continue;
        const r = readiness.acquire();
        readiness.detachLocked(&entry.watcher);
        readiness.releaseLock(r);
        desc.release();
    };

    const deadline: ?u64 = if (timeout_ms > 0) time.monotonicNs() + @as(u64, @intCast(timeout_ms)) * 1_000_000 else null;
    while (true) {
        sched.prepareWait(channel);
        var count: usize = 0;
        for (entries) |*entry| {
            entry.returned = 0;
            if (entry.number < 0) continue;
            const state = if (entry.desc) |desc| fd.readinessOf(desc) else NVAL;
            entry.returned = state & (entry.requested | ALWAYS | NVAL);
            if (entry.returned != 0) count += 1;
        }
        if (count > 0 or timeout_ms == 0) {
            sched.cancelWait();
            return count;
        }
        if (sched.interruptPending()) {
            sched.cancelWait();
            return Error.Interrupted;
        }
        if (deadline) |d| {
            const ms = remaining(d) orelse {
                sched.cancelWait();
                return 0;
            };
            sched.commitWaitTimeout(ms);
        } else sched.commitWait();
    }
}
