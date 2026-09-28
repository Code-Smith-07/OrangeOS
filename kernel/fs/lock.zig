//! Advisory record locks: POSIX fcntl locks (F_GETLK/F_SETLK/F_SETLKW) and
//! Linux open-file-description locks (F_OFD_*).
//!
//! A lock covers a byte range of a file, is shared (read) or exclusive
//! (write), and belongs to an owner. Locks of different owners conflict when
//! their ranges overlap and at least one is exclusive; an owner's own locks
//! never conflict, and a new lock replaces, splits or trims the owner's
//! existing ones over its range. Nothing stops I/O: the locks are advisory,
//! as everywhere.
//!
//! Owners, as on Linux:
//!   * POSIX locks belong to a process. They are released when the process
//!     closes *any* descriptor for the file, and when it exits.
//!   * OFD locks belong to an open file description, shared by dup() and
//!     by descriptors passed to other processes, and are released when the
//!     description's last reference goes.
//!
//! Files are identified by what they are on their filesystem (a tmpfs inode,
//! a CitrusFS inode number, a device), so every path and descriptor for one
//! file sees the same locks. A tmpfs inode cannot be freed while a
//! description refers to it, and every lock goes with the last description,
//! so its key is never reused while a lock names it.
//!
//! One lock covers the table; lists are short (a few locks per open
//! database). F_SETLKW sleeps on the table's channel and retries after any
//! change. A wait that would close a cycle between POSIX owners fails with
//! EDEADLK instead of hanging, as Linux does; OFD waits are not checked,
//! also as on Linux.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");
const vfs = @import("vfs/vfs.zig");

pub const Error = error{ WouldBlock, Deadlock, Interrupted, OutOfMemory, InvalidArgument };

pub const Kind = enum(u8) { read = 0, write = 1 };

/// A process (POSIX locks) or an open file description (OFD locks).
pub const Owner = struct {
    id: u64,

    pub fn process(pid: u32) Owner {
        return .{ .id = @as(u64, pid) << 1 };
    }

    pub fn description(address: usize) Owner {
        return .{ .id = @as(u64, address) | 1 };
    }

    fn isProcess(self: Owner) bool {
        return self.id & 1 == 0;
    }
};

/// The last byte of a lock that runs to the end of the file, however long
/// the file becomes.
pub const TO_END: u64 = std.math.maxInt(u64);

const Lock = struct {
    next: ?*Lock,
    key: u64,
    owner: Owner,
    /// Reported by F_GETLK: the locking process (-1 for an OFD lock).
    pid: i32,
    first: u64,
    last: u64,
    kind: Kind,
};

/// What F_GETLK reports about a conflicting lock.
pub const Conflict = struct { kind: Kind, first: u64, last: u64, pid: i32 };

var lock: spinlock.SpinLock = .{};
var locks: ?*Lock = null;

/// POSIX owners asleep in F_SETLKW and the owner each waits for, for
/// deadlock detection. A wait that finds the table full sleeps unchecked.
const Waiting = struct { waiter: u64 = 0, holder: u64 = 0 };
var waiting: [64]Waiting = [_]Waiting{.{}} ** 64;

fn channel() usize {
    return @intFromPtr(&locks);
}

/// The identity locks are keyed by, or null for files that cannot be
/// locked (directories are refused by the caller).
pub fn keyOf(node: *const vfs.Node) u64 {
    return switch (node.*) {
        .tmp => |inode| @intFromPtr(inode),
        // Kernel pointers have their top bits set; these values do not.
        .citrus => |c| (1 << 40) | @as(u64, c.inode_num),
        .device => |d| (2 << 40) | @as(u64, @intFromEnum(d)),
    };
}

fn overlaps(a_first: u64, a_last: u64, b_first: u64, b_last: u64) bool {
    return a_first <= b_last and b_first <= a_last;
}

fn conflictLocked(key: u64, owner: Owner, first: u64, last: u64, kind: Kind) ?*Lock {
    var cursor = locks;
    while (cursor) |l| : (cursor = l.next) {
        if (l.key != key or l.owner.id == owner.id) continue;
        if (!overlaps(l.first, l.last, first, last)) continue;
        if (l.kind == .write or kind == .write) return l;
    }
    return null;
}

/// F_GETLK: the first lock that would block `kind` over the range, if any.
pub fn find(key: u64, owner: Owner, first: u64, last: u64, kind: Kind) ?Conflict {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    const l = conflictLocked(key, owner, first, last, kind) orelse return null;
    return .{ .kind = l.kind, .first = l.first, .last = l.last, .pid = l.pid };
}

/// Whether `from` waiting for `to` would close a cycle of waiting owners.
fn wouldDeadlockLocked(from: u64, to: u64) bool {
    var holder = to;
    var steps: usize = 0;
    while (steps < waiting.len) : (steps += 1) {
        if (holder == from) return true;
        const next = for (waiting) |w| {
            if (w.waiter == holder) break w.holder;
        } else return false;
        holder = next;
    }
    return false;
}

fn noteWaitingLocked(waiter: u64, holder: u64) ?*Waiting {
    for (&waiting) |*w| {
        if (w.waiter != 0) continue;
        w.* = .{ .waiter = waiter, .holder = holder };
        return w;
    }
    return null;
}

/// Apply `kind` (null: unlock) over [first, last] for `owner`, replacing
/// what the owner held there. `spare` holds two preallocated records: a
/// new lock and, when an old lock is split in two, its second half. Records
/// used are taken out of `spare`.
fn applyLocked(key: u64, owner: Owner, pid: i32, first: u64, last: u64, kind: ?Kind, spare: *[2]?*Lock) ?*Lock {
    var freed: ?*Lock = null;
    var link = &locks;
    while (link.*) |l| {
        if (l.key != key or l.owner.id != owner.id or !overlaps(l.first, l.last, first, last)) {
            link = &l.next;
            continue;
        }
        const keeps_head = l.first < first;
        const keeps_tail = l.last > last;
        if (keeps_head and keeps_tail) {
            // Split: the old lock keeps its head; a new record its tail.
            const tail = spare[1].?;
            spare[1] = null;
            tail.* = l.*;
            tail.first = last + 1;
            l.last = first - 1;
            l.next = tail;
            link = &tail.next;
        } else if (keeps_head) {
            l.last = first - 1;
            link = &l.next;
        } else if (keeps_tail) {
            l.first = last + 1;
            link = &l.next;
        } else {
            link.* = l.next;
            l.next = freed;
            freed = l;
        }
    }
    if (kind) |k| {
        const record = spare[0].?;
        spare[0] = null;
        record.* = .{ .next = locks, .key = key, .owner = owner, .pid = pid, .first = first, .last = last, .kind = k };
        locks = record;
    }
    return freed;
}

fn freeList(list: ?*Lock) void {
    var cursor = list;
    while (cursor) |l| {
        cursor = l.next;
        heap.destroy(l);
    }
}

/// F_SETLK (wait false) and F_SETLKW (wait true). `kind` null unlocks.
/// `last` is inclusive; TO_END runs to the end of the file. Waiting needs
/// interrupts enabled.
pub fn set(key: u64, owner: Owner, pid: i32, first: u64, last: u64, kind: ?Kind, wait: bool) Error!void {
    if (first > last) return Error.InvalidArgument;
    var spare: [2]?*Lock = .{ null, null };
    defer for (spare) |record| if (record) |r| heap.destroy(r);
    for (&spare) |*record| record.* = heap.create(Lock) catch return Error.OutOfMemory;

    while (true) {
        sched.prepareWait(channel());
        const state = spinlock.acquireIrqSave(&lock);
        if (kind) |k| {
            if (conflictLocked(key, owner, first, last, k)) |holder| {
                if (!wait) {
                    spinlock.releaseIrqRestore(&lock, state);
                    sched.cancelWait();
                    return Error.WouldBlock;
                }
                var note: ?*Waiting = null;
                if (owner.isProcess() and holder.owner.isProcess()) {
                    if (wouldDeadlockLocked(owner.id, holder.owner.id)) {
                        spinlock.releaseIrqRestore(&lock, state);
                        sched.cancelWait();
                        return Error.Deadlock;
                    }
                    note = noteWaitingLocked(owner.id, holder.owner.id);
                }
                spinlock.releaseIrqRestore(&lock, state);
                const interrupted = sched.interruptPending();
                if (!interrupted) sched.commitWait() else sched.cancelWait();
                if (note) |w| {
                    const again = spinlock.acquireIrqSave(&lock);
                    w.* = .{};
                    spinlock.releaseIrqRestore(&lock, again);
                }
                if (interrupted) return Error.Interrupted;
                continue;
            }
        }
        const freed = applyLocked(key, owner, pid, first, last, kind, &spare);
        spinlock.releaseIrqRestore(&lock, state);
        sched.cancelWait();
        freeList(freed);
        sched.wakeChannel(channel());
        return;
    }
}

/// Drop every lock `owner` holds on `key` (a POSIX owner closing any
/// descriptor for the file).
pub fn releaseFile(key: u64, owner: Owner) void {
    releaseMatching(owner, key);
}

/// Drop every lock `owner` holds (process exit; an OFD's description
/// closing).
pub fn releaseAll(owner: Owner) void {
    releaseMatching(owner, null);
}

fn releaseMatching(owner: Owner, key: ?u64) void {
    var freed: ?*Lock = null;
    {
        const state = spinlock.acquireIrqSave(&lock);
        defer spinlock.releaseIrqRestore(&lock, state);
        var link = &locks;
        while (link.*) |l| {
            if (l.owner.id == owner.id and (key == null or l.key == key.?)) {
                link.* = l.next;
                l.next = freed;
                freed = l;
            } else link = &l.next;
        }
    }
    if (freed == null) return;
    freeList(freed);
    sched.wakeChannel(channel());
}

/// Locks currently held, for tests.
pub fn count() usize {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    var n: usize = 0;
    var cursor = locks;
    while (cursor) |l| : (cursor = l.next) n += 1;
    return n;
}
