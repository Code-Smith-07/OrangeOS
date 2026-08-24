//! Per-task handle tables.
//!
//! A handle is an index into the owning task's table plus a small base, so a
//! handle value carries no information about the object it names and cannot be
//! guessed into. Passing a handle between processes means translating it: the
//! same object gets a different handle number on the other side.

const std = @import("std");
const object = @import("object.zig");

pub const Error = object.Error;

pub const MAX_HANDLES = 32;

/// Handles start above the standard file descriptors so a program can never
/// confuse one for the other.
pub const HANDLE_BASE: i64 = 100;

pub const Table = struct {
    entries: [MAX_HANDLES]?*object.Object = [_]?*object.Object{null} ** MAX_HANDLES,

    pub fn insert(self: *Table, obj: *object.Object) Error!i64 {
        var i: usize = 0;
        while (i < MAX_HANDLES) : (i += 1) {
            if (self.entries[i] != null) continue;
            self.entries[i] = obj;
            object.retain(obj);
            return @as(i64, @intCast(i)) + HANDLE_BASE;
        }
        return Error.TooManyHandles;
    }

    pub fn get(self: *Table, handle: i64) Error!*object.Object {
        if (handle < HANDLE_BASE) return Error.BadHandle;
        const i = handle - HANDLE_BASE;
        if (i >= MAX_HANDLES) return Error.BadHandle;
        return self.entries[@intCast(i)] orelse Error.BadHandle;
    }

    pub fn getPort(self: *Table, handle: i64) Error!*object.Object {
        const obj = try self.get(handle);
        if (obj.kind != .port) return Error.WrongType;
        return obj;
    }

    pub fn getShm(self: *Table, handle: i64) Error!*object.Object {
        const obj = try self.get(handle);
        if (obj.kind != .shm) return Error.WrongType;
        return obj;
    }

    pub fn getPty(self: *Table, handle: i64) Error!*object.Object {
        const obj = try self.get(handle);
        if (obj.kind != .pty) return Error.WrongType;
        return obj;
    }

    pub fn close(self: *Table, handle: i64) Error!void {
        if (handle < HANDLE_BASE) return Error.BadHandle;
        const i = handle - HANDLE_BASE;
        if (i >= MAX_HANDLES) return Error.BadHandle;
        const idx: usize = @intCast(i);
        const obj = self.entries[idx] orelse return Error.BadHandle;
        object.release(obj);
        self.entries[idx] = null;
    }

    pub fn count(self: *const Table) usize {
        var n: usize = 0;
        for (self.entries) |e| {
            if (e != null) n += 1;
        }
        return n;
    }
};
