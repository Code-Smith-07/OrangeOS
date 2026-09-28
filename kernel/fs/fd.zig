//! Open file descriptions and per-process descriptor tables.
//!
//! A descriptor is a small integer in one process. It refers to an open file
//! description: the object (a file or directory, a pipe end, an eventfd), its
//! access mode and status flags (append, nonblocking) and, for a file, the
//! offset. dup() shares one description, so duplicates share the offset and
//! flags as POSIX requires; close-on-exec belongs to the descriptor slot.
//!
//! Descriptions are reference counted. Table slots and system calls in
//! progress each hold a reference, and the last release closes the object;
//! that is the moment a pipe's reader sees end of file.
//!
//! Every program starts with console descriptions (its terminal, if it has
//! one) at 0, 1 and 2, or with exactly the descriptors its spawner granted.
//! New descriptors take the lowest free number.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const vfs = @import("vfs/vfs.zig");
const pipe = @import("../ipc/pipe.zig");
const eventfd = @import("../ipc/eventfd.zig");
const readiness = @import("../ipc/readiness.zig");
const epoll = @import("../ipc/epoll.zig");
const unix_socket = @import("../ipc/unix_socket.zig");
const inet = @import("../net/socket.zig");
const console_file = @import("console_file.zig");
const record_lock = @import("lock.zig");

pub const Error = vfs.Error;
pub const MAX_OPEN = 256;
/// New descriptors take the lowest free number. 0-2 start as the console,
/// so files begin at 3 unless the program closed one of those.
pub const FD_BASE: i32 = 0;
/// Status bits a description can carry (vfs.OPEN_* values).
const STATUS_MASK: u32 = vfs.OPEN_READ | vfs.OPEN_WRITE | vfs.OPEN_APPEND | vfs.OPEN_NONBLOCK;

pub const Object = union(enum) {
    node: NodeFile,
    pipe_read: *pipe.Pipe,
    pipe_write: *pipe.Pipe,
    eventfd: *eventfd.EventFd,
    epoll: *epoll.Epoll,
    socket: SocketEnd,
    /// A TCP or UDP socket.
    inet: *inet.Socket,
    /// The console or the program's terminal (what 0, 1 and 2 start as).
    console,
};

pub const SocketEnd = struct { pair: *unix_socket.Pair, end: u1 };

pub const NodeFile = struct {
    node: vfs.Node,
    offset: u64 = 0,
    /// A directory's canonical path, for *at() calls relative to it. It is
    /// the path it was opened by; a directory renamed since keeps the old one.
    path: ?[]u8 = null,
};

pub const Description = struct {
    refs: u32 = 1,
    /// Guards `status` changes and a file's offset.
    lock: spinlock.SpinLock = .{},
    status: u32,
    object: Object,

    pub fn create(object: Object, status: u32) Error!*Description {
        const d = heap.create(Description) catch return Error.OutOfMemory;
        d.* = .{ .status = status & STATUS_MASK, .object = object };
        return d;
    }

    pub fn retain(self: *Description) void {
        const previous = @atomicRmw(u32, &self.refs, .Add, 1, .monotonic);
        std.debug.assert(previous > 0);
    }

    /// Take a reference unless the description is already closing. Used by
    /// readiness watchers, which hold no reference of their own.
    pub fn tryRetain(self: *Description) bool {
        var current = @atomicLoad(u32, &self.refs, .acquire);
        while (current != 0) {
            current = @cmpxchgWeak(u32, &self.refs, current, current + 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    pub fn release(self: *Description) void {
        const previous = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        switch (self.object) {
            .node => |n| {
                // Its open-file-description locks go with it.
                record_lock.releaseAll(record_lock.Owner.description(@intFromPtr(self)));
                vfs.release(n.node);
                if (n.path) |path| heap.free(path.ptr);
            },
            .console => {},
            .pipe_read => |p| pipe.closeEnd(p, false),
            .pipe_write => |p| pipe.closeEnd(p, true),
            .eventfd => |e| eventfd.destroy(e),
            .epoll => |ep| epoll.destroy(ep),
            .socket => |sock| unix_socket.closeEnd(sock.pair, sock.end),
            .inet => |sock| inet.close(sock),
        }
        heap.destroy(self);
    }

    pub fn statusFlags(self: *Description) u32 {
        return @atomicLoad(u32, &self.status, .acquire);
    }

    fn nonblocking(self: *Description) bool {
        return self.statusFlags() & vfs.OPEN_NONBLOCK != 0;
    }

    /// The readiness source for epoll, if this object has one. Files are
    /// always ready and have none (epoll refuses them, as Linux does);
    /// nesting epoll instances is not supported.
    pub fn source(self: *Description) ?*readiness.Source {
        return switch (self.object) {
            .node, .epoll, .console => null,
            .pipe_read => |p| pipe.source(p, false),
            .pipe_write => |p| pipe.source(p, true),
            .eventfd => |e| &e.source,
            .socket => |sock| unix_socket.source(sock.pair, sock.end),
            .inet => |sock| inet.source(sock),
        };
    }
};

// ── Descriptor table ────────────────────────────────────────────────────────

pub const Entry = struct { desc: ?*Description = null, cloexec: bool = false };

/// Owned by one process and shared by its threads. The lock covers slots
/// only; it is never held while a description is released or used.
pub const FileTable = struct {
    lock: spinlock.SpinLock = .{},
    /// The process owning the table, whose POSIX record locks on a file go
    /// when it closes any descriptor for that file (0: none, in tests).
    owner_pid: u32 = 0,
    entries: [MAX_OPEN]Entry = [_]Entry{.{}} ** MAX_OPEN,

    pub fn clear(self: *FileTable) void {
        for (&self.entries) |*entry| {
            const desc = blk: {
                const state = spinlock.acquireIrqSave(&self.lock);
                defer spinlock.releaseIrqRestore(&self.lock, state);
                const d = entry.desc orelse continue;
                entry.* = .{};
                break :blk d;
            };
            desc.release();
        }
    }
};

fn index(fd: i32) Error!usize {
    if (fd < 0 or fd >= MAX_OPEN) return Error.BadFd;
    return @intCast(fd);
}

/// Put `desc` in the lowest free slot at or above `min`. Takes over the
/// caller's reference on success only.
pub fn install(table: *FileTable, desc: *Description, min: i32, cloexec: bool) Error!i32 {
    const start: usize = @intCast(@max(min, FD_BASE));
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    if (start >= MAX_OPEN) return Error.InvalidArgument;
    for (table.entries[start..], start..) |*entry, i| {
        if (entry.desc != null) continue;
        entry.* = .{ .desc = desc, .cloexec = cloexec };
        return @intCast(i);
    }
    return Error.TooManyOpen;
}

/// Put `desc` at exactly `fd`, closing whatever was there (dup2). Takes over
/// the caller's reference.
pub fn installAt(table: *FileTable, desc: *Description, fd: i32, cloexec: bool) Error!void {
    const i = index(fd) catch |e| {
        desc.release();
        return e;
    };
    const previous = blk: {
        const state = spinlock.acquireIrqSave(&table.lock);
        defer spinlock.releaseIrqRestore(&table.lock, state);
        const old = table.entries[i].desc;
        table.entries[i] = .{ .desc = desc, .cloexec = cloexec };
        break :blk old;
    };
    if (previous) |d| {
        closedLocks(table, d);
        d.release();
    }
}

/// The description behind `fd` with a reference for the caller, or null if
/// the slot is empty (for 0-2: the console).
pub fn lookup(table: *FileTable, fd: i32) ?*Description {
    const i = index(fd) catch return null;
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    const d = table.entries[i].desc orelse return null;
    d.retain();
    return d;
}

pub fn get(table: *FileTable, fd: i32) Error!*Description {
    return lookup(table, fd) orelse Error.BadFd;
}

pub fn close(table: *FileTable, fd: i32) Error!void {
    const i = try index(fd);
    const desc = blk: {
        const state = spinlock.acquireIrqSave(&table.lock);
        defer spinlock.releaseIrqRestore(&table.lock, state);
        const d = table.entries[i].desc orelse return Error.BadFd;
        table.entries[i] = .{};
        break :blk d;
    };
    closedLocks(table, desc);
    desc.release();
}

/// POSIX: closing any descriptor for a file drops the process's record
/// locks on it, even when other descriptors for the file stay open.
fn closedLocks(table: *FileTable, desc: *Description) void {
    if (table.owner_pid == 0) return;
    switch (desc.object) {
        .node => |*file| record_lock.releaseFile(record_lock.keyOf(&file.node), record_lock.Owner.process(table.owner_pid)),
        else => {},
    }
}

/// dup / F_DUPFD: the lowest free descriptor at or above `min`.
pub fn dup(table: *FileTable, old: i32, min: i32, cloexec: bool) Error!i32 {
    const desc = try get(table, old);
    return install(table, desc, min, cloexec) catch |e| {
        desc.release();
        return e;
    };
}

/// dup2 / dup3: exactly `new`. Duplicating onto itself changes nothing.
pub fn dupTo(table: *FileTable, old: i32, new: i32, cloexec: bool) Error!i32 {
    const desc = try get(table, old);
    if (old == new) {
        desc.release();
        return new;
    }
    try installAt(table, desc, new, cloexec);
    return new;
}

pub fn cloexecOf(table: *FileTable, fd: i32) Error!bool {
    const i = try index(fd);
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    if (table.entries[i].desc == null) return Error.BadFd;
    return table.entries[i].cloexec;
}

pub fn setCloexec(table: *FileTable, fd: i32, cloexec: bool) Error!void {
    const i = try index(fd);
    const state = spinlock.acquireIrqSave(&table.lock);
    defer spinlock.releaseIrqRestore(&table.lock, state);
    if (table.entries[i].desc == null) return Error.BadFd;
    table.entries[i].cloexec = cloexec;
}

/// F_SETFL: only append and nonblocking can change.
pub fn setStatus(table: *FileTable, fd: i32, flags: u32) Error!void {
    const desc = try get(table, fd);
    defer desc.release();
    const changeable = vfs.OPEN_APPEND | vfs.OPEN_NONBLOCK;
    const state = spinlock.acquireIrqSave(&desc.lock);
    defer spinlock.releaseIrqRestore(&desc.lock, state);
    @atomicStore(u32, &desc.status, (desc.status & ~changeable) | (flags & changeable), .release);
}

// ── Creating descriptions ───────────────────────────────────────────────────

/// open(): resolve (and maybe create) `path`, then install it.
pub fn open(table: *FileTable, path: []const u8, flags: u32) Error!i32 {
    if (flags & ~vfs.OPEN_KNOWN != 0) return Error.InvalidArgument;
    var canonical_buffer: [vfs.MAX_PATH]u8 = undefined;
    const canonical = try vfs.normalize(path, &canonical_buffer);
    // Path resolution reads the disk; it runs before taking the table lock.
    const node = try vfs.openNode(canonical, flags);
    const access = (if (flags & vfs.OPEN_WRITE != 0) vfs.OPEN_WRITE | (flags & vfs.OPEN_APPEND) else 0) |
        (if (flags & vfs.OPEN_READ != 0 or flags & vfs.OPEN_WRITE == 0) vfs.OPEN_READ else 0);
    var file: NodeFile = .{ .node = node };
    if (node.isDir()) {
        const copy = heap.alloc(canonical.len) catch {
            vfs.release(node);
            return Error.OutOfMemory;
        };
        @memcpy(copy[0..canonical.len], canonical);
        file.path = copy[0..canonical.len];
    }
    const desc = Description.create(.{ .node = file }, access | (flags & vfs.OPEN_NONBLOCK)) catch |e| {
        vfs.release(node);
        if (file.path) |p| heap.free(p.ptr);
        return e;
    };
    return install(table, desc, FD_BASE, flags & vfs.OPEN_CLOEXEC != 0) catch |e| {
        desc.release();
        return e;
    };
}

/// pipe2(): read end first.
pub fn createPipe(table: *FileTable, nonblock: bool, cloexec: bool) Error![2]i32 {
    const p = pipe.create() catch return Error.OutOfMemory;
    const extra: u32 = if (nonblock) vfs.OPEN_NONBLOCK else 0;
    const reader = Description.create(.{ .pipe_read = p }, vfs.OPEN_READ | extra) catch {
        pipe.closeEnd(p, false);
        pipe.closeEnd(p, true);
        return Error.OutOfMemory;
    };
    const writer = Description.create(.{ .pipe_write = p }, vfs.OPEN_WRITE | extra) catch {
        reader.release();
        pipe.closeEnd(p, true);
        return Error.OutOfMemory;
    };
    const read_fd = install(table, reader, FD_BASE, cloexec) catch |e| {
        reader.release();
        writer.release();
        return e;
    };
    const write_fd = install(table, writer, FD_BASE, cloexec) catch |e| {
        close(table, read_fd) catch {};
        writer.release();
        return e;
    };
    return .{ read_fd, write_fd };
}

pub fn createEventFd(table: *FileTable, initial: u32, semaphore: bool, nonblock: bool, cloexec: bool) Error!i32 {
    const e = eventfd.create(initial, semaphore) catch return Error.OutOfMemory;
    const desc = Description.create(.{ .eventfd = e }, vfs.OPEN_READ | vfs.OPEN_WRITE | (if (nonblock) vfs.OPEN_NONBLOCK else 0)) catch {
        eventfd.destroy(e);
        return Error.OutOfMemory;
    };
    return install(table, desc, FD_BASE, cloexec) catch |err| {
        desc.release();
        return err;
    };
}

// ── Operations on a description ─────────────────────────────────────────────

fn pipeError(e: pipe.Error) Error {
    return switch (e) {
        pipe.Error.WouldBlock => Error.WouldBlock,
        pipe.Error.BrokenPipe => Error.BrokenPipe,
        pipe.Error.Interrupted => Error.Interrupted,
        pipe.Error.OutOfMemory => Error.OutOfMemory,
    };
}

fn eventError(e: eventfd.Error) Error {
    return switch (e) {
        eventfd.Error.WouldBlock => Error.WouldBlock,
        eventfd.Error.Interrupted => Error.Interrupted,
        eventfd.Error.InvalidArgument => Error.InvalidArgument,
        eventfd.Error.OutOfMemory => Error.OutOfMemory,
    };
}

/// A file description's current offset (record locks relative to it).
pub fn position(desc: *Description) u64 {
    return switch (desc.object) {
        .node => offsetOf(desc),
        else => 0,
    };
}

fn offsetOf(desc: *Description) u64 {
    const state = spinlock.acquireIrqSave(&desc.lock);
    defer spinlock.releaseIrqRestore(&desc.lock, state);
    return desc.object.node.offset;
}

fn setOffset(desc: *Description, offset: u64) void {
    const state = spinlock.acquireIrqSave(&desc.lock);
    defer spinlock.releaseIrqRestore(&desc.lock, state);
    desc.object.node.offset = offset;
}

/// Read at the description's position and advance it. Two threads reading one
/// file description at once may both read from the same offset, like pread;
/// the offset ends where the last completed read ended. May block (pipes,
/// eventfds): call with interrupts enabled.
pub fn read(desc: *Description, buf: []u8) Error!usize {
    if (desc.statusFlags() & vfs.OPEN_READ == 0) return Error.BadFd;
    switch (desc.object) {
        .node => |*file| {
            const start = offsetOf(desc);
            const count = try vfs.readAt(&file.node, start, buf);
            setOffset(desc, start + count);
            return count;
        },
        .pipe_read => |p| return pipe.read(p, buf, desc.nonblocking()) catch |e| pipeError(e),
        .eventfd => |e| return eventfd.read(e, buf, desc.nonblocking()) catch |err| eventError(err),
        .socket => |sock| {
            // read() takes data only; descriptions sent along are closed.
            const got = unix_socket.receive(sock.pair, sock.end, buf, desc.nonblocking()) catch |e| return socketError(e);
            for (got.rights[0..got.right_count]) |carried| carried.release();
            return got.bytes;
        },
        .inet => |sock| {
            const got = inet.receive(sock, buf, desc.nonblocking(), false) catch |e| return inetError(e);
            return got.bytes;
        },
        .console => return console_file.read(buf) catch Error.Interrupted,
        .pipe_write, .epoll => return Error.BadFd,
    }
}

/// Write at the description's position (its end, when appending) and advance
/// it. May block; call with interrupts enabled.
pub fn write(desc: *Description, data: []const u8) Error!usize {
    const status = desc.statusFlags();
    if (status & vfs.OPEN_WRITE == 0) return Error.BadFd;
    switch (desc.object) {
        .node => |*file| {
            const at: ?u64 = if (status & vfs.OPEN_APPEND != 0) null else offsetOf(desc);
            const written = try vfs.writeNode(&file.node, at, data);
            setOffset(desc, written.end);
            return written.count;
        },
        .pipe_write => |p| return pipe.write(p, data, desc.nonblocking()) catch |e| pipeError(e),
        .eventfd => |e| return eventfd.write(e, data, desc.nonblocking()) catch |err| eventError(err),
        .socket => |sock| return unix_socket.send(sock.pair, sock.end, data, &.{}, desc.nonblocking()) catch |e| socketError(e),
        .inet => |sock| return inet.send(sock, data, null, desc.nonblocking()) catch |e| inetError(e),
        .console => return console_file.write(data),
        .pipe_read, .epoll => return Error.BadFd,
    }
}

/// What read() and write() report for socket failures. The syscall layer
/// maps the socket calls' own errors in full (inetErrno).
pub fn inetError(e: inet.Error) Error {
    return switch (e) {
        inet.Error.WouldBlock, inet.Error.InProgress => Error.WouldBlock,
        inet.Error.Interrupted => Error.Interrupted,
        inet.Error.OutOfMemory => Error.OutOfMemory,
        inet.Error.BrokenPipe, inet.Error.Reset => Error.BrokenPipe,
        inet.Error.MessageTooLong => Error.MessageTooLong,
        inet.Error.NotPermitted => Error.NotPermitted,
        else => Error.IoError,
    };
}

pub fn socketError(e: unix_socket.Error) Error {
    return switch (e) {
        unix_socket.Error.WouldBlock => Error.WouldBlock,
        unix_socket.Error.BrokenPipe => Error.BrokenPipe,
        unix_socket.Error.Interrupted => Error.Interrupted,
        unix_socket.Error.OutOfMemory => Error.OutOfMemory,
        unix_socket.Error.MessageTooLong => Error.MessageTooLong,
        unix_socket.Error.InvalidArgument => Error.InvalidArgument,
    };
}

/// pread: read at an explicit offset, leaving the description's alone.
pub fn readAtOffset(desc: *Description, offset: u64, buf: []u8) Error!usize {
    if (desc.statusFlags() & vfs.OPEN_READ == 0) return Error.BadFd;
    return switch (desc.object) {
        .node => |*file| vfs.readAt(&file.node, offset, buf),
        else => Error.NotSeekable,
    };
}

/// pwrite: write at an explicit offset. Unlike Linux, an append description
/// still writes at the given offset, as POSIX specifies.
pub fn writeAtOffset(desc: *Description, offset: u64, data: []const u8) Error!usize {
    if (desc.statusFlags() & vfs.OPEN_WRITE == 0) return Error.BadFd;
    return switch (desc.object) {
        .node => |*file| (try vfs.writeNode(&file.node, offset, data)).count,
        else => Error.NotSeekable,
    };
}

pub fn truncate(desc: *Description, length: u64) Error!void {
    if (desc.statusFlags() & vfs.OPEN_WRITE == 0) return Error.InvalidArgument;
    switch (desc.object) {
        .node => |*file| try vfs.truncateNode(&file.node, length),
        else => return Error.InvalidArgument,
    }
}

pub const Whence = enum(u32) { set = 0, current = 1, end = 2 };

/// lseek: move relative to the start, the current offset or the end, and
/// return the new offset. Pipes and other streams cannot seek.
pub fn seek(desc: *Description, offset: i64, whence: Whence) Error!u64 {
    const file = switch (desc.object) {
        .node => |*file| file,
        else => return Error.NotSeekable,
    };
    // The size of a tmpfs file is read under its own lock, not this one.
    const end = file.node.size();
    const state = spinlock.acquireIrqSave(&desc.lock);
    defer spinlock.releaseIrqRestore(&desc.lock, state);
    const base: i128 = switch (whence) {
        .set => 0,
        .current => file.offset,
        .end => end,
    };
    const target = base + offset;
    if (target < 0 or target > std.math.maxInt(i64)) return Error.InvalidArgument;
    file.offset = @intCast(target);
    return file.offset;
}

pub const Kind = enum(u32) { file = 1, directory = 2, console = 3, pipe = 4, socket = 5, anonymous = 6, device = 7 };
pub const Status = struct { size: u64, kind: Kind, mode: u32 };

pub fn stat(desc: *Description) Status {
    const mode = desc.statusFlags();
    return switch (desc.object) {
        .node => |*file| .{
            .size = file.node.size(),
            .kind = if (file.node.isDir()) .directory else if (file.node == .device) .device else .file,
            .mode = mode,
        },
        .pipe_read => |p| .{ .size = pipe.bytesAvailable(p), .kind = .pipe, .mode = mode },
        .pipe_write => .{ .size = 0, .kind = .pipe, .mode = mode },
        .eventfd, .epoll => .{ .size = 0, .kind = .anonymous, .mode = mode },
        .socket => |sock| .{ .size = unix_socket.pending(sock.pair, sock.end), .kind = .socket, .mode = mode },
        .inet => |sock| .{ .size = inet.pending(sock), .kind = .socket, .mode = mode },
        .console => .{ .size = 0, .kind = .console, .mode = mode },
    };
}

/// Current readiness as poll/epoll event bits.
pub fn readinessOf(desc: *Description) u32 {
    return switch (desc.object) {
        // Regular files and directories never block.
        .node => epoll.IN | epoll.RDNORM | epoll.OUT | epoll.WRNORM,
        .pipe_read => |p| blk: {
            const r = pipe.poll(p);
            var bits: u32 = 0;
            if (r.readable) bits |= epoll.IN | epoll.RDNORM;
            if (r.hangup) bits |= epoll.HUP | epoll.RDHUP;
            break :blk bits;
        },
        .pipe_write => |p| blk: {
            const r = pipe.poll(p);
            var bits: u32 = 0;
            if (r.writable) bits |= epoll.OUT | epoll.WRNORM;
            if (r.peer_closed) bits |= epoll.ERR;
            break :blk bits;
        },
        .eventfd => |e| blk: {
            const r = eventfd.poll(e);
            var bits: u32 = 0;
            if (r.readable) bits |= epoll.IN | epoll.RDNORM;
            if (r.writable) bits |= epoll.OUT | epoll.WRNORM;
            break :blk bits;
        },
        .epoll => 0,
        // Output never blocks; input readiness is not tracked yet.
        .console => epoll.OUT | epoll.WRNORM,
        .socket => |sock| blk: {
            const r = unix_socket.poll(sock.pair, sock.end);
            var bits: u32 = 0;
            if (r.readable) bits |= epoll.IN | epoll.RDNORM;
            if (r.writable) bits |= epoll.OUT | epoll.WRNORM;
            if (r.read_hangup) bits |= epoll.RDHUP;
            if (r.hangup) bits |= epoll.HUP;
            break :blk bits;
        },
        .inet => |sock| blk: {
            const r = inet.poll(sock);
            var bits: u32 = 0;
            if (r.readable) bits |= epoll.IN | epoll.RDNORM;
            if (r.writable) bits |= epoll.OUT | epoll.WRNORM;
            if (r.failed) bits |= epoll.ERR;
            if (r.read_hangup) bits |= epoll.RDHUP;
            if (r.hangup) bits |= epoll.HUP;
            break :blk bits;
        },
    };
}

/// socket(AF_INET, ...): a new unconnected TCP or UDP socket.
pub fn createInetSocket(table: *FileTable, kind: inet.Kind, nonblock: bool, cloexec: bool) Error!i32 {
    const sock = inet.create(kind) catch return Error.OutOfMemory;
    const status = vfs.OPEN_READ | vfs.OPEN_WRITE | (if (nonblock) vfs.OPEN_NONBLOCK else 0);
    const desc = Description.create(.{ .inet = sock }, status) catch {
        inet.close(sock);
        return Error.OutOfMemory;
    };
    return install(table, desc, FD_BASE, cloexec) catch |e| {
        desc.release();
        return e;
    };
}

/// socketpair(): two connected ends.
pub fn createSocketPair(table: *FileTable, kind: unix_socket.Kind, nonblock: bool, cloexec: bool) Error![2]i32 {
    const pair = unix_socket.create(kind) catch return Error.OutOfMemory;
    const status = vfs.OPEN_READ | vfs.OPEN_WRITE | (if (nonblock) vfs.OPEN_NONBLOCK else 0);
    const first = Description.create(.{ .socket = .{ .pair = pair, .end = 0 } }, status) catch {
        unix_socket.closeEnd(pair, 0);
        unix_socket.closeEnd(pair, 1);
        return Error.OutOfMemory;
    };
    const second = Description.create(.{ .socket = .{ .pair = pair, .end = 1 } }, status) catch {
        first.release();
        unix_socket.closeEnd(pair, 1);
        return Error.OutOfMemory;
    };
    const a = install(table, first, FD_BASE, cloexec) catch |e| {
        first.release();
        second.release();
        return e;
    };
    const b = install(table, second, FD_BASE, cloexec) catch |e| {
        close(table, a) catch {};
        second.release();
        return e;
    };
    return .{ a, b };
}

pub fn createEpoll(table: *FileTable, cloexec: bool) Error!i32 {
    const ep = epoll.create() catch return Error.OutOfMemory;
    const desc = Description.create(.{ .epoll = ep }, vfs.OPEN_READ) catch {
        epoll.destroy(ep);
        return Error.OutOfMemory;
    };
    return install(table, desc, FD_BASE, cloexec) catch |e| {
        desc.release();
        return e;
    };
}

/// A read of an open directory, whose offset is an entry index: `begin`
/// takes a reference and the starting index, `entries` visits the entries,
/// and `end` advances the offset past the ones delivered.
pub const DirRead = struct {
    desc: *Description,
    start_offset: u64,

    pub fn begin(table: *FileTable, fd: i32) Error!DirRead {
        const desc = try get(table, fd);
        const is_dir = switch (desc.object) {
            .node => |*file| file.node.isDir(),
            else => false,
        };
        if (!is_dir) {
            desc.release();
            return Error.NotDirectory;
        }
        return .{ .desc = desc, .start_offset = offsetOf(desc) };
    }

    pub fn start(self: *const DirRead) u64 {
        return self.start_offset;
    }

    pub fn entries(
        self: *const DirRead,
        ctx: *anyopaque,
        visit: *const fn (ctx: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool,
    ) Error!void {
        try vfs.iterateNode(&self.desc.object.node.node, ctx, visit);
    }

    pub fn end(self: *const DirRead, delivered: u64) void {
        setOffset(self.desc, self.start_offset + delivered);
        self.desc.release();
    }
};

// ── Table-level conveniences ────────────────────────────────────────────────

pub fn readFd(table: *FileTable, fd: i32, buf: []u8) Error!usize {
    const desc = try get(table, fd);
    defer desc.release();
    return read(desc, buf);
}

pub fn writeFd(table: *FileTable, fd: i32, data: []const u8) Error!usize {
    const desc = try get(table, fd);
    defer desc.release();
    return write(desc, data);
}

pub fn seekFd(table: *FileTable, fd: i32, offset: i64, whence: Whence) Error!u64 {
    const desc = try get(table, fd);
    defer desc.release();
    return seek(desc, offset, whence);
}

pub fn statFd(table: *FileTable, fd: i32) Error!Status {
    const desc = try get(table, fd);
    defer desc.release();
    return stat(desc);
}

/// Give a new program the console at 0, 1 and 2, where nothing was
/// installed for it.
pub fn installConsole(table: *FileTable) Error!void {
    for (0..3) |i| {
        const number: i32 = @intCast(i);
        if (lookup(table, number)) |existing| {
            existing.release();
            continue;
        }
        const desc = try Description.create(.console, vfs.OPEN_READ | vfs.OPEN_WRITE);
        installAt(table, desc, number, false) catch {};
    }
}

/// The canonical path of the directory behind `fd`, copied into `out`.
pub fn directoryPath(table: *FileTable, number: i32, out: *[vfs.MAX_PATH]u8) Error![]const u8 {
    const desc = try get(table, number);
    defer desc.release();
    const path = switch (desc.object) {
        .node => |*file| file.path orelse return Error.NotDirectory,
        else => return Error.NotDirectory,
    };
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}
