//! IPC operations.
//!
//! Two planes, deliberately separate:
//!
//!   CONTROL — ports. Small messages, copied by the kernel. Simple, safe,
//!             and the cost of the copy is irrelevant at this size.
//!
//!   DATA    — shared memory. The kernel maps the same physical frames into
//!             two address spaces and then gets out of the way. A 4 MiB
//!             window buffer is never memcpy'd through the kernel; the
//!             sender writes it and sends a 32-byte "it changed" message.
//!
//! Getting this split right is what keeps the compositor in Phase 7 from
//! spending all its time in the kernel.

const event = @import("../drivers/input/event.zig");
const std = @import("std");
const object = @import("object.zig");
const handle = @import("handle.zig");
const sched = @import("../sched/sched.zig");
const task_mod = @import("../sched/task.zig");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const io = @import("../arch/x86_64/io.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Error = object.Error;
pub const Header = object.Header;
pub const MAX_PAYLOAD = object.MAX_PAYLOAD;

fn currentTable() Error!*handle.Table {
    const t = sched.currentTask() orelse return Error.BadHandle;
    return &t.handles;
}

/// Create a named port and return a handle to it.
pub fn portCreate(name: []const u8) Error!i64 {
    const obj = try object.createPort(name);
    const table = try currentTable();
    return table.insert(obj);
}

/// Get a handle to an existing port by name.
pub fn portConnect(name: []const u8) Error!i64 {
    const obj = object.findPort(name) orelse return Error.NoSuchPort;
    const table = try currentTable();
    return table.insert(obj);
}

/// Queue a message on a port. Returns the sequence number stamped on it.
/// The port the compositor serves clients on, if it has registered one.
///
/// The compositor has two independent things to wait for - client messages and
/// input events - and a thread can only be on one wait queue. Rather than poll
/// both, it waits on input and registers its port here, so a client message
/// wakes the same channel. One wait point, no polling, no added latency on
/// either path.
var input_sink: ?*object.Port = null;
var input_sink_lock: spinlock.SpinLock = .{};

pub fn setInputSink(h: i64) Error!void {
    const table = try currentTable();
    const obj = try table.getPort(h);
    const state = spinlock.acquireIrqSave(&input_sink_lock);
    defer spinlock.releaseIrqRestore(&input_sink_lock, state);
    input_sink = &obj.data.port;
}

/// Whether the compositor's client port already has work queued.
///
/// `sysInputWait` registers its wait first and checks this second. A sender
/// that races the check either makes this return true or removes the waiter,
/// so a client message cannot be stranded behind a missed wakeup.
pub fn inputPending() bool {
    const state = spinlock.acquireIrqSave(&input_sink_lock);
    const port = input_sink;
    spinlock.releaseIrqRestore(&input_sink_lock, state);

    const p = port orelse return false;
    return !p.isEmpty();
}

fn isInputSink(port: *object.Port) bool {
    const state = spinlock.acquireIrqSave(&input_sink_lock);
    defer spinlock.releaseIrqRestore(&input_sink_lock, state);
    return input_sink == port;
}

pub fn portSend(h: i64, opcode: u32, payload: []const u8) Error!u64 {
    if (payload.len > MAX_PAYLOAD) return Error.MessageTooLarge;

    const table = try currentTable();
    const obj = try table.getPort(h);
    const port = &obj.data.port;

    const msg = try object.allocMessage();
    errdefer object.freeMessage(msg);

    const sender: u32 = if (sched.currentTask()) |t| t.tid else 0;
    msg.header = .{
        .opcode = opcode,
        .len = @intCast(payload.len),
        .seq = 0,
        .sender = sender,
    };
    @memcpy(msg.payload[0..payload.len], payload);

    // `errdefer` owns cleanup on failure. Freeing explicitly here as well
    // would return the same message to the allocator twice.
    port.push(msg) catch return Error.QueueFull;

    // Anyone blocked on this port has work now.
    sched.wakeChannel(@intFromPtr(port));
    if (isInputSink(port)) sched.wakeChannel(event.waitChannel());

    return msg.header.seq;
}

pub const Received = struct {
    header: Header,
    len: usize,
};

/// Take the next message from a port, blocking until one arrives.
///
/// Blocking is a yield loop rather than a wait queue. A wait queue needs the
/// sender to know who is waiting, which needs per-port waiter lists; that is
/// worth building when there are enough ports for the polling to cost
/// something.
pub fn portRecv(h: i64, out: []u8, blocking: bool) Error!Received {
    const table = try currentTable();
    const obj = try table.getPort(h);
    const port = &obj.data.port;

    // The caller arrived through the syscall gate with IF clear. A blocking
    // receive that never re-enables interrupts can never be woken.
    if (blocking) io.sti();
    defer if (blocking) io.cli();

    const chan = @intFromPtr(port);
    while (true) {
        // Register before testing, so a send landing in the window between the
        // test and the sleep unlinks us instead of being missed.
        sched.prepareWait(chan);

        if (port.pop()) |msg| {
            sched.cancelWait();
            const n = @min(out.len, msg.header.len);
            @memcpy(out[0..n], msg.payload[0..n]);
            const hdr = msg.header;
            object.freeMessage(msg);
            return .{ .header = hdr, .len = n };
        }
        if (!blocking) {
            sched.cancelWait();
            return Error.QueueEmpty;
        }
        sched.commitWait();
    }
}

/// Allocate a named shared memory object and return a handle.
/// An empty name makes it anonymous and unfindable by anyone else.
pub fn shmCreate(name: []const u8, size: usize) Error!i64 {
    if (size == 0 or size > 4 * 1024 * 1024) return Error.OutOfMemory;
    const obj = try object.createShm(name, size);
    const table = try currentTable();
    return table.insert(obj);
}

/// Get a handle to an existing named shared buffer.
pub fn shmOpen(name: []const u8) Error!i64 {
    const obj = object.findShm(name) orelse return Error.NoSuchPort;
    const table = try currentTable();
    return table.insert(obj);
}

/// Map a shared memory object into the calling process and return the address.
/// Both processes get the same physical frames, so a write by one is visible
/// to the other with no kernel involvement at all.
pub fn shmMap(h: i64, writable: bool) Error!u64 {
    const t = sched.currentTask() orelse return Error.BadHandle;
    const obj = try t.handles.getShm(h);
    const shm = &obj.data.shm;

    const base = t.shm_next;
    var flags: u64 = vmm.PRESENT | vmm.USER | vmm.NO_EXECUTE;
    if (writable) flags |= vmm.WRITABLE;

    var off: usize = 0;
    while (off < shm.size) : (off += vmm.PAGE_SIZE) {
        vmm.mapPage(t.address_space, base + off, shm.phys + off, flags) catch {
            return Error.OutOfMemory;
        };
        vmm.invalidatePage(base + off);
    }

    // Leave a guard page between mappings so an overrun faults instead of
    // silently landing in the next object.
    t.shm_next = base + shm.size + vmm.PAGE_SIZE;
    return base;
}

pub fn shmSize(h: i64) Error!usize {
    const table = try currentTable();
    const obj = try table.getShm(h);
    return obj.data.shm.size;
}

pub fn handleClose(h: i64) Error!void {
    const table = try currentTable();
    return table.close(h);
}
