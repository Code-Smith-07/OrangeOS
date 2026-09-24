//! IPC objects and the capability model.
//!
//! Userspace never sees a kernel pointer. It holds *handles* — small integers
//! that index a table private to each process. A handle from one process is
//! meaningless in another, and there is no arithmetic a process can do on one
//! to reach an object it was not given. That is what makes them capabilities
//! rather than just names.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const pty_mod = @import("pty.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Error = error{
    OutOfMemory,
    NoSuchPort,
    NameTaken,
    NameTooLong,
    BadHandle,
    WrongType,
    QueueFull,
    QueueEmpty,
    MessageTooLarge,
    TooManyHandles,
};

pub const MAX_NAME = 32;
pub const MAX_PAYLOAD = 4096;
pub const QUEUE_DEPTH = 16;

pub const Kind = enum(u8) {
    port,
    shm,
    pty,
};

/// Message header. Mirrors kernel/include/ipc_abi.h and pulp's Message.
pub const Header = extern struct {
    magic: u32 = MAGIC,
    opcode: u32 = 0,
    len: u32 = 0,
    nhandles: u32 = 0,
    seq: u64 = 0,
    sender: u32 = 0,
    flags: u32 = 0,

    pub const MAGIC: u32 = 0x4F52_4750; // "ORGP"
};

pub const Message = struct {
    header: Header,
    payload: [MAX_PAYLOAD]u8,
};

/// A named message port. Any process that knows the name may connect; a
/// production system would gate that on a namespace, which is future work.
pub const Port = struct {
    name: [MAX_NAME]u8,
    name_len: usize,

    queue: [QUEUE_DEPTH]*Message,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    lock: spinlock.SpinLock = .{},

    /// Sequence number stamped on each message, so a reply can be matched.
    next_seq: u64 = 1,

    pub fn nameSlice(self: *const Port) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isEmpty(self: *Port) bool {
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);
        return self.count == 0;
    }

    pub fn push(self: *Port, msg: *Message) Error!u64 {
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);

        if (self.count == QUEUE_DEPTH) return Error.QueueFull;
        msg.header.seq = self.next_seq;
        self.next_seq += 1;
        const seq = msg.header.seq;
        self.queue[self.tail] = msg;
        self.tail = (self.tail + 1) % QUEUE_DEPTH;
        self.count += 1;
        return seq;
    }

    pub fn pop(self: *Port) ?*Message {
        const state = spinlock.acquireIrqSave(&self.lock);
        defer spinlock.releaseIrqRestore(&self.lock, state);

        if (self.count == 0) return null;
        const m = self.queue[self.head];
        self.head = (self.head + 1) % QUEUE_DEPTH;
        self.count -= 1;
        return m;
    }
};

/// A block of physical pages that more than one address space can map.
/// The kernel never copies the contents: it hands out the same frames.
pub const Shm = struct {
    /// Physical base and the buddy order it was allocated at.
    phys: u64,
    order: usize,
    size: usize,

    /// Shared buffers are named so a second process can find one without the
    /// first having to pass a handle through a message. Handle transfer is the
    /// better answer and arrives later; a name is enough to build the display
    /// protocol on now.
    name: [MAX_NAME]u8,
    name_len: usize,

    pub fn nameSlice(self: *const Shm) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Object = struct {
    kind: Kind,
    refs: u32,
    data: union {
        port: Port,
        shm: Shm,
        pty: pty_mod.Pty,
    },
};

// ── Object registry ─────────────────────────────────────────────────────────

pub const MAX_OBJECTS = 64;

var objects: [MAX_OBJECTS]?*Object = [_]?*Object{null} ** MAX_OBJECTS;
var registry_lock: spinlock.SpinLock = .{};
var object_count: usize = 0; // high-water mark; empty slots are reused

/// Caller holds registry_lock. The returned reference belongs to the caller.
fn allocObjectLocked() Error!*Object {
    var slot: usize = 0;
    while (slot < object_count and objects[slot] != null) : (slot += 1) {}
    if (slot >= MAX_OBJECTS) return Error.OutOfMemory;
    const obj = heap.create(Object) catch return Error.OutOfMemory;
    objects[slot] = obj;
    if (slot == object_count) object_count += 1;
    return obj;
}

fn findPortLocked(name: []const u8) ?*Object {
    for (objects[0..object_count]) |maybe| {
        const obj = maybe orelse continue;
        if (obj.kind == .port and std.mem.eql(u8, obj.data.port.nameSlice(), name)) return obj;
    }
    return null;
}

fn findShmLocked(name: []const u8) ?*Object {
    for (objects[0..object_count]) |maybe| {
        const obj = maybe orelse continue;
        if (obj.kind == .shm and std.mem.eql(u8, obj.data.shm.nameSlice(), name)) return obj;
    }
    return null;
}

pub fn createPort(name: []const u8) Error!*Object {
    if (name.len == 0 or name.len > MAX_NAME) return Error.NameTooLong;
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    if (findPortLocked(name) != null) return Error.NameTaken;
    const obj = try allocObjectLocked();
    obj.* = .{ .kind = .port, .refs = 1, .data = .{ .port = undefined } };

    const p = &obj.data.port;
    p.* = .{ .name = undefined, .name_len = name.len, .queue = undefined };
    @memcpy(p.name[0..name.len], name);
    return obj;
}

pub fn acquirePort(name: []const u8) ?*Object {
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    const obj = findPortLocked(name) orelse return null;
    obj.refs += 1;
    return obj;
}

pub fn acquireShm(name: []const u8) ?*Object {
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    const obj = findShmLocked(name) orelse return null;
    obj.refs += 1;
    return obj;
}

pub fn createShm(name: []const u8, size: usize) Error!*Object {
    if (name.len > MAX_NAME) return Error.NameTooLong;
    const pages = (size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const order = pmm.orderFor(pages);
    const phys = pmm.allocOrderZeroed(order) catch return Error.OutOfMemory;

    const state = spinlock.acquireIrqSave(&registry_lock);
    if (name.len > 0 and findShmLocked(name) != null) {
        spinlock.releaseIrqRestore(&registry_lock, state);
        pmm.freeOrder(phys, order);
        return Error.NameTaken;
    }
    const obj = allocObjectLocked() catch {
        spinlock.releaseIrqRestore(&registry_lock, state);
        pmm.freeOrder(phys, order);
        return Error.OutOfMemory;
    };
    obj.* = .{
        .kind = .shm,
        .refs = 1,
        .data = .{ .shm = .{
            .phys = phys,
            .order = order,
            .size = pages * pmm.PAGE_SIZE,
            .name = undefined,
            .name_len = name.len,
        } },
    };
    if (name.len > 0) @memcpy(obj.data.shm.name[0..name.len], name);
    spinlock.releaseIrqRestore(&registry_lock, state);
    return obj;
}

pub fn createPty() Error!*Object {
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    const obj = try allocObjectLocked();
    obj.* = .{ .kind = .pty, .refs = 1, .data = .{ .pty = .{} } };
    return obj;
}

pub fn retain(obj: *Object) void {
    const state = spinlock.acquireIrqSave(&registry_lock);
    obj.refs += 1;
    spinlock.releaseIrqRestore(&registry_lock, state);
}

pub fn release(obj: *Object) void {
    const state = spinlock.acquireIrqSave(&registry_lock);
    std.debug.assert(obj.refs > 0);
    obj.refs -= 1;
    if (obj.refs != 0) {
        spinlock.releaseIrqRestore(&registry_lock, state);
        return;
    }
    for (objects[0..object_count]) |*entry| {
        if (entry.* == obj) {
            entry.* = null;
            break;
        }
    }
    while (object_count > 0 and objects[object_count - 1] == null) object_count -= 1;
    spinlock.releaseIrqRestore(&registry_lock, state);

    switch (obj.kind) {
        .port => {
            const port = &obj.data.port;
            while (port.pop()) |msg| freeMessage(msg);
        },
        .shm => pmm.freeOrder(obj.data.shm.phys, obj.data.shm.order),
        .pty => {},
    }
    heap.destroy(obj);
}

pub fn allocMessage() Error!*Message {
    return heap.create(Message) catch Error.OutOfMemory;
}

pub fn freeMessage(m: *Message) void {
    heap.destroy(m);
}

pub fn portCount() usize {
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    var n: usize = 0;
    var i: usize = 0;
    while (i < object_count) : (i += 1) {
        if (objects[i]) |o| {
            if (o.kind == .port) n += 1;
        }
    }
    return n;
}

pub fn objectCount() usize {
    const state = spinlock.acquireIrqSave(&registry_lock);
    defer spinlock.releaseIrqRestore(&registry_lock, state);
    var count: usize = 0;
    for (objects[0..object_count]) |entry| if (entry != null) {
        count += 1;
    };
    return count;
}
