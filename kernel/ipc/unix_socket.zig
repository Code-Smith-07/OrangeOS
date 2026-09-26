//! Connected local socket pairs (socketpair) with descriptor passing.
//!
//! A pair has one queue per direction, each holding up to CAPACITY bytes of
//! segments. A segment is the data of one send plus any open file
//! descriptions sent with it (SCM_RIGHTS), each carried with a reference of
//! its own.
//!
//! Stream sockets deliver bytes in order and may split or join sends, but a
//! read never runs from plain data into a segment that carries descriptions:
//! those arrive with the first bytes read from their segment, as on Linux.
//! Datagram and seqpacket sockets deliver whole messages, truncating one that
//! does not fit the reader's buffer.
//!
//! Closing an end discards what was sent to it, releasing any descriptions in
//! flight, and wakes the peer, which sees end of file or EPIPE. A socket sent
//! through its own queue keeps itself alive until the other end closes; there
//! is no cycle collector.
//!
//! Waiters register on the pair's channel before checking, as for pipes.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");
const readiness = @import("readiness.zig");
const fd = @import("../fs/fd.zig");

pub const CAPACITY = 256 * 1024;
/// Descriptions in one message.
pub const MAX_RIGHTS = 64;

pub const Kind = enum { stream, datagram, seqpacket };

pub const Error = error{ WouldBlock, BrokenPipe, Interrupted, OutOfMemory, MessageTooLong, InvalidArgument };

const Segment = struct {
    next: ?*Segment = null,
    data: []u8,
    /// Bytes already read (stream sockets consume segments partially).
    consumed: usize = 0,
    rights: [MAX_RIGHTS]*fd.Description = undefined,
    right_count: u8 = 0,

    fn remaining(self: *const Segment) usize {
        return self.data.len - self.consumed;
    }
};

const Queue = struct {
    head: ?*Segment = null,
    tail: ?*Segment = null,
    bytes: usize = 0,

    fn push(self: *Queue, segment: *Segment) void {
        if (self.tail) |tail| tail.next = segment else self.head = segment;
        self.tail = segment;
        self.bytes += segment.data.len;
    }

    fn pop(self: *Queue) ?*Segment {
        const segment = self.head orelse return null;
        self.head = segment.next;
        if (self.head == null) self.tail = null;
        segment.next = null;
        return segment;
    }
};

pub const Pair = struct {
    lock: spinlock.SpinLock = .{},
    kind: Kind,
    /// queues[i]: data sent to end i.
    queues: [2]Queue = .{ .{}, .{} },
    open: [2]bool = .{ true, true },
    /// shutdown(): end i reads no more / writes no more.
    read_shut: [2]bool = .{ false, false },
    write_shut: [2]bool = .{ false, false },
    sources: [2]readiness.Source = .{ .{}, .{} },

    fn channel(self: *const Pair) usize {
        return @intFromPtr(self);
    }
};

pub fn create(kind: Kind) Error!*Pair {
    const pair = heap.create(Pair) catch return Error.OutOfMemory;
    pair.* = .{ .kind = kind };
    return pair;
}

pub fn source(pair: *Pair, end: u1) *readiness.Source {
    return &pair.sources[end];
}

fn changed(pair: *Pair) void {
    sched.wakeChannel(pair.channel());
    readiness.notify(&pair.sources[0]);
    readiness.notify(&pair.sources[1]);
}

fn freeSegment(segment: *Segment) void {
    for (segment.rights[0..segment.right_count]) |desc| desc.release();
    heap.free(segment.data.ptr);
    heap.destroy(segment);
}

/// Send `data` and, with the first byte, `rights` (each already referenced
/// for the message; on failure those references stay with the caller).
/// Returns the bytes queued. May block; call with interrupts enabled.
pub fn send(pair: *Pair, from: u1, data: []const u8, rights: []const *fd.Description, nonblock: bool) Error!usize {
    const to: u1 = from ^ 1;
    if (rights.len > MAX_RIGHTS) return Error.InvalidArgument;
    const whole = pair.kind != .stream;
    if (whole and data.len > CAPACITY) return Error.MessageTooLong;
    if (data.len == 0 and rights.len == 0 and pair.kind == .stream) return 0;
    while (true) {
        sched.prepareWait(pair.channel());
        const state = spinlock.acquireIrqSave(&pair.lock);
        if (!pair.open[to] or pair.read_shut[to] or pair.write_shut[from]) {
            spinlock.releaseIrqRestore(&pair.lock, state);
            sched.cancelWait();
            return Error.BrokenPipe;
        }
        const space = CAPACITY - pair.queues[to].bytes;
        const fits = if (whole) space >= data.len else space > 0 or data.len == 0;
        if (fits) {
            spinlock.releaseIrqRestore(&pair.lock, state);
            sched.cancelWait();
            // Build the segment without the lock, then queue it; a racing
            // sender may take the space meanwhile, so check again.
            const count = if (whole) data.len else @min(data.len, space);
            const segment = heap.create(Segment) catch return Error.OutOfMemory;
            const copy = heap.alloc(@max(count, 1)) catch {
                heap.destroy(segment);
                return Error.OutOfMemory;
            };
            @memcpy(copy[0..count], data[0..count]);
            segment.* = .{ .data = copy[0..count], .right_count = @intCast(rights.len) };
            @memcpy(segment.rights[0..rights.len], rights);
            const again = spinlock.acquireIrqSave(&pair.lock);
            const still_open = pair.open[to] and !pair.read_shut[to] and !pair.write_shut[from];
            const room = CAPACITY - pair.queues[to].bytes >= count;
            if (still_open and (room or count == 0)) {
                pair.queues[to].push(segment);
                spinlock.releaseIrqRestore(&pair.lock, again);
                changed(pair);
                return count;
            }
            spinlock.releaseIrqRestore(&pair.lock, again);
            // Give the references back to the caller and retry or fail.
            segment.right_count = 0;
            freeSegment(segment);
            if (!still_open) return Error.BrokenPipe;
            continue;
        }
        spinlock.releaseIrqRestore(&pair.lock, state);
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

pub const Received = struct {
    bytes: usize,
    rights: [MAX_RIGHTS]*fd.Description = undefined,
    right_count: usize = 0,
    /// A datagram was longer than the buffer; the rest was discarded.
    truncated: bool = false,
};

/// Receive into `buf`. Descriptions that arrive are returned with their
/// references for the caller to install or release. Returns 0 bytes and no
/// rights at end of stream. May block; call with interrupts enabled.
pub fn receive(pair: *Pair, at: u1, buf: []u8, nonblock: bool) Error!Received {
    const from: u1 = at ^ 1;
    while (true) {
        sched.prepareWait(pair.channel());
        const state = spinlock.acquireIrqSave(&pair.lock);
        const queue = &pair.queues[at];
        if (queue.head != null and !pair.read_shut[at]) {
            var result: Received = .{ .bytes = 0 };
            var finished: ?*Segment = null;
            if (pair.kind == .stream) {
                while (queue.head) |segment| {
                    // Never run from plain data into a segment with rights.
                    if (result.bytes > 0 and segment.right_count > 0 and segment.consumed == 0) break;
                    if (segment.right_count > 0) {
                        @memcpy(result.rights[0..segment.right_count], segment.rights[0..segment.right_count]);
                        result.right_count = segment.right_count;
                        segment.right_count = 0;
                    }
                    const count = @min(buf.len - result.bytes, segment.remaining());
                    @memcpy(buf[result.bytes .. result.bytes + count], segment.data[segment.consumed .. segment.consumed + count]);
                    segment.consumed += count;
                    result.bytes += count;
                    queue.bytes -= count;
                    if (segment.remaining() == 0) {
                        _ = queue.pop();
                        segment.next = finished;
                        finished = segment;
                    }
                    if (result.bytes == buf.len) break;
                }
            } else {
                const segment = queue.pop().?;
                queue.bytes -= segment.data.len;
                const count = @min(buf.len, segment.data.len);
                @memcpy(buf[0..count], segment.data[0..count]);
                result.bytes = count;
                result.truncated = count < segment.data.len;
                @memcpy(result.rights[0..segment.right_count], segment.rights[0..segment.right_count]);
                result.right_count = segment.right_count;
                segment.right_count = 0;
                finished = segment;
            }
            spinlock.releaseIrqRestore(&pair.lock, state);
            sched.cancelWait();
            while (finished) |segment| {
                finished = segment.next;
                freeSegment(segment);
            }
            changed(pair);
            return result;
        }
        const ended = !pair.open[from] or pair.write_shut[from] or pair.read_shut[at];
        spinlock.releaseIrqRestore(&pair.lock, state);
        if (ended) {
            sched.cancelWait();
            return .{ .bytes = 0 };
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

/// shutdown(): 0 stop reading, 1 stop writing, 2 both.
pub fn shutdown(pair: *Pair, end: u1, how: u2) void {
    const state = spinlock.acquireIrqSave(&pair.lock);
    if (how == 0 or how == 2) pair.read_shut[end] = true;
    if (how == 1 or how == 2) pair.write_shut[end] = true;
    spinlock.releaseIrqRestore(&pair.lock, state);
    changed(pair);
}

pub const Ready = struct { readable: bool, writable: bool, hangup: bool, read_hangup: bool };

pub fn poll(pair: *Pair, end: u1) Ready {
    const peer: u1 = end ^ 1;
    const state = spinlock.acquireIrqSave(&pair.lock);
    defer spinlock.releaseIrqRestore(&pair.lock, state);
    const peer_gone = !pair.open[peer];
    const peer_done_writing = peer_gone or pair.write_shut[peer];
    const space = CAPACITY - pair.queues[peer].bytes;
    return .{
        .readable = pair.queues[end].head != null or peer_done_writing or pair.read_shut[end],
        .writable = !peer_gone and !pair.read_shut[peer] and !pair.write_shut[end] and space >= 4096,
        .hangup = peer_gone or (pair.write_shut[end] and peer_done_writing),
        .read_hangup = peer_done_writing,
    };
}

pub fn pending(pair: *Pair, end: u1) usize {
    const state = spinlock.acquireIrqSave(&pair.lock);
    defer spinlock.releaseIrqRestore(&pair.lock, state);
    return pair.queues[end].bytes;
}

/// The end's description closed: discard what was sent to it (releasing
/// descriptions in flight) and free the pair once both ends are gone.
pub fn closeEnd(pair: *Pair, end: u1) void {
    readiness.detachAll(&pair.sources[end]);
    const state = spinlock.acquireIrqSave(&pair.lock);
    pair.open[end] = false;
    var discarded = pair.queues[end].head;
    pair.queues[end] = .{};
    const gone = !pair.open[0] and !pair.open[1];
    spinlock.releaseIrqRestore(&pair.lock, state);
    while (discarded) |segment| {
        discarded = segment.next;
        freeSegment(segment);
    }
    changed(pair);
    if (gone) heap.destroy(pair);
}
