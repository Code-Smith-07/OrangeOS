//! Per-process handle tables.
//!
//! A handle is an index into the owning process's table plus a small base, so
//! a handle value carries no information about the object it names and cannot
//! be guessed into. Passing a handle between processes means translating it:
//! the same object gets a different handle number on the other side.
//!
//! Threads of one program share the table. Every lookup therefore returns its
//! own reference, taken under the table lock: another thread closing the
//! handle meanwhile only drops the table's reference, never the one in use.
//! Callers release what they acquire.

const std = @import("std");
const object = @import("object.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Error = object.Error;

pub const MAX_HANDLES = 32;

/// Handles start above the standard file descriptors so a program can never
/// confuse one for the other.
pub const HANDLE_BASE: i64 = 100;

pub const Table = struct {
    lock: spinlock.SpinLock = .{},
    entries: [MAX_HANDLES]?*object.Object = [_]?*object.Object{null} ** MAX_HANDLES,

    pub fn insert(self: *Table, obj: *object.Object) Error!i64 {
        object.retain(obj);
        errdefer object.release(obj);
        return self.insertOwned(obj);
    }

    /// Consume an existing reference, including the creator/acquire reference.
    pub fn insertOwned(self: *Table, obj: *object.Object) Error!i64 {
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);
        for (&self.entries, 0..) |*entry, i| {
            if (entry.* != null) continue;
            entry.* = obj;
            return @as(i64, @intCast(i)) + HANDLE_BASE;
        }
        return Error.TooManyHandles;
    }

    fn index(handle: i64) Error!usize {
        if (handle < HANDLE_BASE) return Error.BadHandle;
        const i = handle - HANDLE_BASE;
        if (i >= MAX_HANDLES) return Error.BadHandle;
        return @intCast(i);
    }

    /// A new reference to the object behind `handle`, if it has `kind`.
    pub fn acquire(self: *Table, handle: i64, kind: object.Kind) Error!*object.Object {
        const i = try index(handle);
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);
        const obj = self.entries[i] orelse return Error.BadHandle;
        if (obj.kind != kind) return Error.WrongType;
        object.retain(obj);
        return obj;
    }

    pub fn close(self: *Table, handle: i64) Error!void {
        const i = try index(handle);
        const state = spinlock.acquireIrqSave(&self.lock);
        const obj = self.entries[i] orelse {
            spinlock.releaseIrqRestore(&self.lock, state);
            return Error.BadHandle;
        };
        self.entries[i] = null;
        spinlock.releaseIrqRestore(&self.lock, state);
        // Outside the table lock: the last release may free the object.
        object.release(obj);
    }

    /// Close every handle. Used when the last thread of a program exits.
    pub fn releaseAll(self: *Table) void {
        var taken: [MAX_HANDLES]?*object.Object = undefined;
        const state = spinlock.acquireIrqSave(&self.lock);
        taken = self.entries;
        self.entries = [_]?*object.Object{null} ** MAX_HANDLES;
        spinlock.releaseIrqRestore(&self.lock, state);
        for (taken) |entry| {
            if (entry) |obj| object.release(obj);
        }
    }

    pub fn count(self: *Table) usize {
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);
        var n: usize = 0;
        for (self.entries) |e| {
            if (e != null) n += 1;
        }
        return n;
    }
};
