//! TCP.
//!
//! A connection is a state machine over an unreliable channel, and almost all
//! of the difficulty is in the arithmetic rather than the states. Sequence
//! numbers are 32-bit and wrap, so every comparison is done modulo 2^32:
//! `a < b` is wrong and `(a - b)` read as signed is right.
//!
//! What this implements: active open with the MSS option; a 64 KiB receive
//! ring whose free space is the advertised window; a 64 KiB send ring with
//! as many segments in flight as the peer's window allows; retransmission
//! with exponential back-off (go-back-N from the oldest unacknowledged
//! byte); zero-window probes; orderly close in both directions (FIN_WAIT,
//! CLOSING, TIME_WAIT, CLOSE_WAIT, LAST_ACK); resets in both directions,
//! including a reset for segments that match no connection; keepalive.
//!
//! What it does not: passive open (listen/accept), out-of-order reassembly
//! (a segment ahead of rcv_nxt is dropped and acknowledged, and the peer
//! resends it), congestion control, window scaling, SACK and timestamps.
//! Each costs throughput on lossy or long paths, not correctness.
//!
//! Every field is network state: touched only under the network lock
//! (net.zig). The network thread runs `timersLocked` every millisecond and
//! delivers segments as they arrive; callers of the functions here wait on
//! `waitChannel` for a change. Changes wake that channel and notify the
//! readiness source of the socket using the connection, if any.
//!
//! A connection outlives its user: closing a socket queues a FIN and leaves
//! the connection "detached" to finish the handshake; the timers free it
//! once it is closed.

const std = @import("std");
const net = @import("net.zig");
const heap = @import("../mm/heap.zig");
const tsc = @import("../time/tsc.zig");
const sched = @import("../sched/sched.zig");
const readiness = @import("../ipc/readiness.zig");
const random = @import("../lib/random.zig");

pub const Error = error{
    NoSockets,
    NotConnected,
    Refused,
    Timeout,
    TooLarge,
    Reset,
    OutOfMemory,
    WouldBlock,
    Interrupted,
    Unreachable,
    BrokenPipe,
    AddressInUse,
};

const FLAG_FIN: u8 = 1 << 0;
const FLAG_SYN: u8 = 1 << 1;
const FLAG_RST: u8 = 1 << 2;
const FLAG_PSH: u8 = 1 << 3;
const FLAG_ACK: u8 = 1 << 4;

const PROTO_TCP: u8 = 6;

/// The largest payload one Ethernet frame carries (1500 - 20 - 20).
pub const MSS: u16 = 1460;
/// What a peer that sends no MSS option accepts (RFC 9293).
const DEFAULT_PEER_MSS: u16 = 536;
pub const RX_CAPACITY: usize = 64 * 1024;
pub const TX_CAPACITY: usize = 64 * 1024;
/// No window scaling: the advertised window field is 16 bits.
const MAX_WINDOW: usize = 65535;

const SYN_RTO_US: u64 = 1_000_000;
const INITIAL_RTO_US: u64 = 400_000;
const MAX_RTO_US: u64 = 16_000_000;
const MAX_SYN_RETRIES: u32 = 6;
const MAX_RETRIES: u32 = 10;
const TIME_WAIT_US: u64 = 10_000_000;
/// A detached connection stuck waiting for the peer's FIN gives up, as
/// Linux's tcp_fin_timeout does.
const ORPHAN_FIN_WAIT_US: u64 = 60_000_000;
const KEEPALIVE_IDLE_US: u64 = 7200 * 1_000_000;
const KEEPALIVE_INTERVAL_US: u64 = 75 * 1_000_000;
const KEEPALIVE_PROBES: u32 = 9;

pub const State = enum(u8) {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    close_wait,
    last_ack,
};

pub const Tcb = struct {
    next: ?*Tcb = null,
    state: State = .closed,

    local_port: u16 = 0,
    remote_ip: net.Ipv4Addr = .{ 0, 0, 0, 0 },
    remote_port: u16 = 0,

    /// Send sequence space: snd_una is the oldest unacknowledged sequence
    /// number, snd_nxt the next to send, snd_wnd the peer's window.
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_wnd: u32 = 0,
    peer_mss: u16 = DEFAULT_PEER_MSS,
    /// Receive sequence space.
    rcv_nxt: u32 = 0,
    /// The window last advertised, to send an update when reading opens it.
    advertised: usize = 0,

    /// Received in order and not yet read.
    rx: []u8,
    rx_head: usize = 0,
    rx_len: usize = 0,
    /// Written by the user from snd_una on: sent but unacknowledged, then
    /// not yet sent.
    tx: []u8,
    tx_head: usize = 0,
    tx_len: usize = 0,

    /// No more data will be written; a FIN follows the queued bytes.
    fin_queued: bool = false,
    /// The FIN occupies the sequence number before snd_nxt.
    fin_sent: bool = false,
    peer_fin: bool = false,
    /// Why the connection failed, for the user to collect once.
    failure: ?Error = null,

    rto_us: u64 = INITIAL_RTO_US,
    /// When to retransmit (or probe a zero window); 0 when idle.
    retransmit_at: u64 = 0,
    retries: u32 = 0,
    /// TIME_WAIT's end, and a detached FIN_WAIT_2's deadline.
    deadline: u64 = 0,
    last_heard: u64 = 0,
    keepalive: bool = false,
    keepalive_sent: u32 = 0,
    keepalive_at: u64 = 0,

    /// In use by a socket or a legacy slot; the timers free it otherwise
    /// once it is closed.
    attached: bool = true,
    /// Woken on every change: the waiting socket's channel, and its
    /// readiness source.
    wake_channel: usize = 0,
    source: ?*readiness.Source = null,

    pub fn failureError(self: *const Tcb) ?Error {
        return self.failure;
    }
};

var connections: ?*Tcb = null;
var next_port: u16 = 32768;

// ── Sequence arithmetic ─────────────────────────────────────────────────────

inline fn seqGE(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

inline fn seqGT(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

inline fn seqLE(a: u32, b: u32) bool {
    return seqGE(b, a);
}

// ── Header helpers ──────────────────────────────────────────────────────────

inline fn putBe16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v >> 8);
    buf[off + 1] = @truncate(v);
}

inline fn putBe32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v >> 24);
    buf[off + 1] = @truncate(v >> 16);
    buf[off + 2] = @truncate(v >> 8);
    buf[off + 3] = @truncate(v);
}

inline fn be16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}

inline fn be32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | buf[off + 3];
}

/// The one's-complement sum over the pseudo-header and segment. Sending,
/// it is the checksum to store; receiving, a valid segment sums to zero.
fn tcpChecksum(src: net.Ipv4Addr, dst: net.Ipv4Addr, seg: []const u8) u16 {
    var sum: u32 = 0;
    sum += (@as(u32, src[0]) << 8) | src[1];
    sum += (@as(u32, src[2]) << 8) | src[3];
    sum += (@as(u32, dst[0]) << 8) | dst[1];
    sum += (@as(u32, dst[2]) << 8) | dst[3];
    sum += PROTO_TCP;
    sum += @as(u32, @intCast(seg.len));

    var i: usize = 0;
    while (i + 1 < seg.len) : (i += 2) {
        sum += (@as(u32, seg[i]) << 8) | seg[i + 1];
    }
    if (i < seg.len) sum += @as(u32, seg[i]) << 8;

    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

// ── Notification ────────────────────────────────────────────────────────────

fn changed(c: *Tcb) void {
    if (c.wake_channel != 0) sched.wakeChannel(c.wake_channel);
    if (c.source) |source| readiness.notify(source);
}

// ── Output ──────────────────────────────────────────────────────────────────

fn windowToAdvertise(c: *const Tcb) usize {
    return @min(c.rx.len - c.rx_len, MAX_WINDOW);
}

/// Send one segment: `flags`, sequence number `seq`, and `length` bytes of
/// the send ring starting `offset` bytes after snd_una. A SYN carries the
/// MSS option.
fn transmit(c: *Tcb, flags: u8, seq: u32, offset: usize, length: usize) void {
    var seg: [24 + MSS]u8 = undefined;
    const header: usize = if (flags & FLAG_SYN != 0) 24 else 20;
    putBe16(&seg, 0, c.local_port);
    putBe16(&seg, 2, c.remote_port);
    putBe32(&seg, 4, seq);
    putBe32(&seg, 8, if (flags & FLAG_ACK != 0) c.rcv_nxt else 0);
    seg[12] = @intCast((header / 4) << 4);
    seg[13] = flags;
    const window = windowToAdvertise(c);
    c.advertised = window;
    putBe16(&seg, 14, @intCast(window));
    putBe16(&seg, 16, 0);
    putBe16(&seg, 18, 0);
    if (header == 24) {
        seg[20] = 2; // MSS
        seg[21] = 4;
        putBe16(&seg, 22, MSS);
    }
    var copied: usize = 0;
    while (copied < length) {
        const at = (c.tx_head + offset + copied) % c.tx.len;
        const run = @min(length - copied, c.tx.len - at);
        @memcpy(seg[header + copied .. header + copied + run], c.tx[at .. at + run]);
        copied += run;
    }
    const total = header + length;
    putBe16(&seg, 16, tcpChecksum(net.local_ip, c.remote_ip, seg[0..total]));
    // An unresolved next hop is queued behind its ARP request (net.zig).
    net.sendRawLocked(c.remote_ip, PROTO_TCP, seg[0..total]) catch {};
}

fn sendAck(c: *Tcb) void {
    transmit(c, FLAG_ACK, c.snd_nxt, 0, 0);
}

/// A reset for a segment that matched no connection (RFC 9293 3.10.7.1).
fn sendResetFor(src_ip: net.Ipv4Addr, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, length: u32) void {
    var seg: [20]u8 = undefined;
    putBe16(&seg, 0, dst_port);
    putBe16(&seg, 2, src_port);
    if (flags & FLAG_ACK != 0) {
        putBe32(&seg, 4, ack);
        putBe32(&seg, 8, 0);
        seg[13] = FLAG_RST;
    } else {
        var consumed = length;
        if (flags & FLAG_SYN != 0) consumed += 1;
        if (flags & FLAG_FIN != 0) consumed += 1;
        putBe32(&seg, 4, 0);
        putBe32(&seg, 8, seq +% consumed);
        seg[13] = FLAG_RST | FLAG_ACK;
    }
    seg[12] = 5 << 4;
    putBe16(&seg, 14, 0);
    putBe16(&seg, 16, 0);
    putBe16(&seg, 18, 0);
    putBe16(&seg, 16, tcpChecksum(net.local_ip, src_ip, &seg));
    net.sendRawLocked(src_ip, PROTO_TCP, &seg) catch {};
}

fn armRetransmit(c: *Tcb, now: u64) void {
    if (c.retransmit_at == 0) c.retransmit_at = now + c.rto_us;
}

/// Bytes sent and unacknowledged, not counting the FIN.
fn sentData(c: *const Tcb) usize {
    const in_flight: usize = c.snd_nxt -% c.snd_una;
    return in_flight - @intFromBool(c.fin_sent);
}

/// Send what the peer's window allows, then the FIN once the data is out.
/// `probe` lets one byte through a zero window.
fn output(c: *Tcb, probe: bool) void {
    switch (c.state) {
        .established, .close_wait, .fin_wait_1, .last_ack, .closing => {},
        else => return,
    }
    const now = tsc.microsSinceBoot();
    const mss: usize = @min(c.peer_mss, MSS);
    var allow_probe = probe;
    while (!c.fin_sent) {
        const sent = sentData(c);
        const unsent = c.tx_len - sent;
        if (unsent == 0) break;
        const in_flight: usize = c.snd_nxt -% c.snd_una;
        var usable: usize = if (c.snd_wnd > in_flight) c.snd_wnd - in_flight else 0;
        if (usable == 0 and allow_probe and in_flight == 0) {
            usable = 1;
            allow_probe = false;
        }
        if (usable == 0) {
            // Nothing in flight to be acknowledged: the persist timer asks
            // again when the window may have opened.
            armRetransmit(c, now);
            return;
        }
        const n = @min(unsent, usable, mss);
        transmit(c, FLAG_ACK | FLAG_PSH, c.snd_nxt, sent, n);
        c.snd_nxt +%= @intCast(n);
        armRetransmit(c, now);
    }
    if (c.fin_queued and !c.fin_sent and sentData(c) == c.tx_len) {
        transmit(c, FLAG_ACK | FLAG_FIN, c.snd_nxt, 0, 0);
        c.snd_nxt +%= 1;
        c.fin_sent = true;
        c.state = switch (c.state) {
            .established => .fin_wait_1,
            .close_wait => .last_ack,
            else => c.state,
        };
        armRetransmit(c, now);
    }
}

/// The connection is over: tell whoever uses it why.
fn fail(c: *Tcb, why: Error) void {
    if (c.failure == null) c.failure = why;
    c.state = .closed;
    c.retransmit_at = 0;
    changed(c);
}

// ── Input ───────────────────────────────────────────────────────────────────

fn findConn(local_port: u16, remote_ip: net.Ipv4Addr, remote_port: u16) ?*Tcb {
    var cursor = connections;
    while (cursor) |c| : (cursor = c.next) {
        if (c.state == .closed) continue;
        if (c.local_port != local_port or c.remote_port != remote_port) continue;
        if (!std.mem.eql(u8, &c.remote_ip, &remote_ip)) continue;
        return c;
    }
    return null;
}

fn parseMss(options: []const u8) ?u16 {
    var i: usize = 0;
    while (i < options.len) {
        const kind = options[i];
        if (kind == 0) break;
        if (kind == 1) {
            i += 1;
            continue;
        }
        if (i + 1 >= options.len) break;
        const len = options[i + 1];
        if (len < 2 or i + len > options.len) break;
        if (kind == 2 and len == 4) return be16(options, i + 2);
        i += len;
    }
    return null;
}

/// Drop `count` acknowledged bytes from the front of the send ring.
fn consumeSent(c: *Tcb, count: usize) void {
    c.tx_head = (c.tx_head + count) % c.tx.len;
    c.tx_len -= count;
}

fn appendReceived(c: *Tcb, data: []const u8) usize {
    const space = c.rx.len - c.rx_len;
    const n = @min(data.len, space);
    var copied: usize = 0;
    while (copied < n) {
        const at = (c.rx_head + c.rx_len + copied) % c.rx.len;
        const run = @min(n - copied, c.rx.len - at);
        @memcpy(c.rx[at .. at + run], data[copied .. copied + run]);
        copied += run;
    }
    c.rx_len += n;
    return n;
}

/// A segment for this host. Caller holds the network lock.
pub fn input(segment: []const u8, src_ip: net.Ipv4Addr) void {
    if (segment.len < 20) return;
    if (tcpChecksum(src_ip, net.local_ip, segment) != 0) return;

    const src_port = be16(segment, 0);
    const dst_port = be16(segment, 2);
    const seq = be32(segment, 4);
    const ack = be32(segment, 8);
    const offset: usize = @as(usize, segment[12] >> 4) * 4;
    const flags = segment[13];
    const window = be16(segment, 14);
    if (offset < 20 or offset > segment.len) return;
    const data = segment[offset..];

    const c = findConn(dst_port, src_ip, src_port) orelse {
        if (flags & FLAG_RST == 0) sendResetFor(src_ip, src_port, dst_port, seq, ack, flags, @intCast(data.len));
        return;
    };
    const now = tsc.microsSinceBoot();
    c.last_heard = now;
    c.keepalive_sent = 0;
    c.keepalive_at = 0;

    if (flags & FLAG_RST != 0) {
        switch (c.state) {
            .syn_sent => if (flags & FLAG_ACK != 0 and ack == c.snd_nxt) fail(c, Error.Refused),
            .time_wait => fail(c, Error.Reset),
            // Only a reset at the expected sequence number counts, so a
            // blind reset needs the right guess (RFC 5961, simplified).
            else => if (seq == c.rcv_nxt) fail(c, Error.Reset),
        }
        return;
    }

    if (c.state == .syn_sent) {
        if (flags & FLAG_SYN == 0 or flags & FLAG_ACK == 0 or ack != c.snd_nxt) {
            if (flags & FLAG_ACK != 0 and ack != c.snd_nxt) sendResetFor(src_ip, src_port, dst_port, seq, ack, flags, 0);
            return;
        }
        c.rcv_nxt = seq +% 1;
        c.snd_una = ack;
        c.snd_wnd = window;
        c.peer_mss = parseMss(segment[20..offset]) orelse DEFAULT_PEER_MSS;
        c.state = .established;
        c.retransmit_at = 0;
        c.retries = 0;
        c.rto_us = INITIAL_RTO_US;
        sendAck(c);
        output(c, false);
        changed(c);
        return;
    }

    var notify = false;
    if (flags & FLAG_ACK != 0 and seqGT(ack, c.snd_una) and seqLE(ack, c.snd_nxt)) {
        var acked: usize = ack -% c.snd_una;
        const fin_acked = c.fin_sent and ack == c.snd_nxt;
        if (fin_acked) acked -= 1;
        consumeSent(c, acked);
        c.snd_una = ack;
        c.retries = 0;
        c.rto_us = INITIAL_RTO_US;
        c.retransmit_at = if (c.snd_una != c.snd_nxt) now + c.rto_us else 0;
        notify = true;
        if (fin_acked) {
            c.state = switch (c.state) {
                .fin_wait_1 => if (c.peer_fin) .time_wait else .fin_wait_2,
                .closing => .time_wait,
                .last_ack => .closed,
                else => c.state,
            };
            if (c.state == .time_wait) c.deadline = now + TIME_WAIT_US;
            if (c.state == .fin_wait_2 and !c.attached) c.deadline = now + ORPHAN_FIN_WAIT_US;
        }
    }
    if (flags & FLAG_ACK != 0 and seqGE(ack, c.snd_una)) {
        const opened = c.snd_wnd == 0 and window > 0;
        c.snd_wnd = window;
        if (opened) notify = true;
    }

    if (data.len > 0) {
        switch (c.state) {
            .established, .fin_wait_1, .fin_wait_2 => if (seq == c.rcv_nxt) {
                const taken = appendReceived(c, data);
                c.rcv_nxt +%= @intCast(taken);
                if (taken > 0) notify = true;
            },
            else => {},
        }
        // Acknowledge everything, in order or not, so the peer resends what
        // is missing.
        sendAck(c);
    }

    if (flags & FLAG_FIN != 0 and !c.peer_fin and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
        c.rcv_nxt +%= 1;
        c.peer_fin = true;
        sendAck(c);
        notify = true;
        c.state = switch (c.state) {
            .established => .close_wait,
            .fin_wait_1 => if (c.fin_sent and c.snd_una == c.snd_nxt) .time_wait else .closing,
            .fin_wait_2 => .time_wait,
            else => c.state,
        };
        if (c.state == .time_wait) c.deadline = now + TIME_WAIT_US;
    } else if (flags & FLAG_FIN != 0 and c.state == .time_wait) {
        sendAck(c); // our last ACK was lost
    }

    output(c, false);
    if (notify) changed(c);
}

// ── Timers ──────────────────────────────────────────────────────────────────

fn freeTcb(c: *Tcb) void {
    heap.free(c.rx.ptr);
    heap.free(c.tx.ptr);
    heap.destroy(c);
}

/// Retransmissions, zero-window probes, TIME_WAIT, keepalive, and freeing
/// detached connections that are done. Returns whether any connection is
/// still active, so the network thread knows how often to call again.
/// Caller holds the network lock.
pub fn timersLocked() bool {
    const now = tsc.microsSinceBoot();
    var active = false;
    var link = &connections;
    while (link.*) |c| {
        if (c.state == .closed) {
            if (!c.attached) {
                link.* = c.next;
                freeTcb(c);
                continue;
            }
            link = &c.next;
            continue;
        }
        active = true;
        if (c.retransmit_at != 0 and now >= c.retransmit_at) retransmit(c, now);
        if ((c.state == .time_wait or (c.state == .fin_wait_2 and !c.attached)) and c.deadline != 0 and now >= c.deadline) {
            c.state = .closed;
            changed(c);
        }
        if (c.keepalive and c.state == .established) keepalive(c, now);
        link = &c.next;
    }
    return active;
}

fn retransmit(c: *Tcb, now: u64) void {
    c.retransmit_at = 0;
    if (c.state == .syn_sent) {
        if (c.retries >= MAX_SYN_RETRIES) return fail(c, Error.Timeout);
        c.retries += 1;
        c.rto_us = @min(c.rto_us * 2, MAX_RTO_US);
        transmit(c, FLAG_SYN, c.snd_una, 0, 0);
        c.retransmit_at = now + c.rto_us;
        return;
    }
    if (c.snd_una == c.snd_nxt) {
        // Nothing in flight: the persist timer for a zero window.
        output(c, true);
        return;
    }
    if (c.retries >= MAX_RETRIES) {
        transmit(c, FLAG_RST | FLAG_ACK, c.snd_nxt, 0, 0);
        return fail(c, Error.Timeout);
    }
    c.retries += 1;
    c.rto_us = @min(c.rto_us * 2, MAX_RTO_US);
    // Go back to the oldest unacknowledged byte and send again from there;
    // an unacknowledged FIN goes out again after the data, and the state
    // (FIN_WAIT_1, CLOSING or LAST_ACK) stays as it is.
    c.snd_nxt = c.snd_una;
    c.fin_sent = false;
    output(c, true);
    if (c.retransmit_at == 0) c.retransmit_at = now + c.rto_us;
}

fn keepalive(c: *Tcb, now: u64) void {
    if (c.keepalive_at == 0) {
        c.keepalive_at = @max(c.last_heard, 1) + KEEPALIVE_IDLE_US;
        return;
    }
    if (now < c.keepalive_at) return;
    if (c.keepalive_sent >= KEEPALIVE_PROBES) {
        transmit(c, FLAG_RST | FLAG_ACK, c.snd_nxt, 0, 0);
        return fail(c, Error.Timeout);
    }
    // A segment one byte before snd_una: the peer must acknowledge it.
    transmit(c, FLAG_ACK, c.snd_una -% 1, 0, 0);
    c.keepalive_sent += 1;
    c.keepalive_at = now + KEEPALIVE_INTERVAL_US;
}

// ── For sockets ─────────────────────────────────────────────────────────────

/// A new, closed connection with its buffers. Not yet on the list.
pub fn create() Error!*Tcb {
    const rx = heap.alloc(RX_CAPACITY) catch return Error.OutOfMemory;
    const tx = heap.alloc(TX_CAPACITY) catch {
        heap.free(rx);
        return Error.OutOfMemory;
    };
    const c = heap.create(Tcb) catch {
        heap.free(rx);
        heap.free(tx);
        return Error.OutOfMemory;
    };
    c.* = .{ .rx = rx[0..RX_CAPACITY], .tx = tx[0..TX_CAPACITY] };
    return c;
}

/// Free a connection that never joined the list.
pub fn destroyUnused(c: *Tcb) void {
    freeTcb(c);
}

fn portInUseLocked(port: u16) bool {
    var cursor = connections;
    while (cursor) |c| : (cursor = c.next) {
        if (c.state != .closed and c.local_port == port) return true;
    }
    return false;
}

/// An ephemeral port no live connection uses (32768-60999, as Linux).
pub fn ephemeralPortLocked() ?u16 {
    var tries: usize = 0;
    while (tries < 28232) : (tries += 1) {
        const port = next_port;
        next_port = if (next_port >= 60999) 32768 else next_port + 1;
        if (!portInUseLocked(port)) return port;
    }
    return null;
}

pub fn portBusyLocked(port: u16) bool {
    return portInUseLocked(port);
}

/// Active open: send the SYN. Completion arrives through `input`.
/// `local_port` 0 picks an ephemeral port. Caller holds the network lock.
pub fn connectLocked(c: *Tcb, dst_ip: net.Ipv4Addr, dst_port: u16, local_port: u16) Error!void {
    const port = if (local_port != 0) local_port else ephemeralPortLocked() orelse return Error.AddressInUse;
    var iss_bytes: [4]u8 = undefined;
    random.fill(&iss_bytes, .insecure) catch {};
    const iss = std.mem.readInt(u32, &iss_bytes, .little);
    c.local_port = port;
    c.remote_ip = dst_ip;
    c.remote_port = dst_port;
    c.snd_una = iss;
    c.snd_nxt = iss +% 1;
    c.state = .syn_sent;
    c.rto_us = SYN_RTO_US;
    c.last_heard = tsc.microsSinceBoot();
    c.next = connections;
    connections = c;
    transmit(c, FLAG_SYN, iss, 0, 0);
    c.retransmit_at = tsc.microsSinceBoot() + c.rto_us;
}

/// Queue bytes to send. Returns how many fit (0 when the ring is full).
/// Caller holds the network lock.
pub fn writeLocked(c: *Tcb, data: []const u8) usize {
    const space = c.tx.len - c.tx_len;
    const n = @min(space, data.len);
    var copied: usize = 0;
    while (copied < n) {
        const at = (c.tx_head + c.tx_len + copied) % c.tx.len;
        const run = @min(n - copied, c.tx.len - at);
        @memcpy(c.tx[at .. at + run], data[copied .. copied + run]);
        copied += run;
    }
    c.tx_len += n;
    if (n > 0) output(c, false);
    return n;
}

pub fn sendSpaceLocked(c: *const Tcb) usize {
    return c.tx.len - c.tx_len;
}

/// Copy received bytes out; `consume` false peeks. Reading enough to reopen
/// a small window sends a window update. Caller holds the network lock.
pub fn readLocked(c: *Tcb, out: []u8, consume: bool) usize {
    const n = @min(out.len, c.rx_len);
    var copied: usize = 0;
    while (copied < n) {
        const at = (c.rx_head + copied) % c.rx.len;
        const run = @min(n - copied, c.rx.len - at);
        @memcpy(out[copied .. copied + run], c.rx[at .. at + run]);
        copied += run;
    }
    if (consume and n > 0) {
        c.rx_head = (c.rx_head + n) % c.rx.len;
        c.rx_len -= n;
        const now_open = windowToAdvertise(c);
        if (c.state != .closed and c.state != .syn_sent and c.advertised < 2 * @as(usize, MSS) and now_open >= 2 * @as(usize, MSS))
            sendAck(c);
    }
    return n;
}

pub fn pendingLocked(c: *const Tcb) usize {
    return c.rx_len;
}

/// No more data from this side: a FIN follows what is queued.
pub fn shutdownWriteLocked(c: *Tcb) void {
    if (c.fin_queued) return;
    c.fin_queued = true;
    output(c, false);
    changed(c);
}

/// Abandon the connection with a reset.
pub fn abortLocked(c: *Tcb) void {
    switch (c.state) {
        .closed => {},
        .syn_sent => c.state = .closed,
        else => {
            transmit(c, FLAG_RST | FLAG_ACK, c.snd_nxt, 0, 0);
            c.state = .closed;
        },
    }
    c.retransmit_at = 0;
    changed(c);
}

/// The user is gone. Unread data or an unfinished open end the connection
/// with a reset, as Linux does; otherwise it closes gracefully in the
/// background and the timers free it. Caller holds the network lock.
pub fn detachLocked(c: *Tcb) void {
    c.attached = false;
    c.source = null;
    c.wake_channel = 0;
    switch (c.state) {
        .closed => {},
        .syn_sent => c.state = .closed,
        else => if (c.rx_len > 0) abortLocked(c) else {
            c.fin_queued = true;
            output(c, false);
            if (c.state == .fin_wait_2) c.deadline = tsc.microsSinceBoot() + ORPHAN_FIN_WAIT_US;
        },
    }
}

pub const Readiness = struct { readable: bool, writable: bool, failed: bool, hangup: bool, read_hangup: bool };

pub fn pollLocked(c: *const Tcb) Readiness {
    const connected = switch (c.state) {
        .established, .close_wait, .fin_wait_1, .fin_wait_2, .closing, .last_ack, .time_wait => true,
        else => false,
    };
    const failed = c.failure != null;
    const writable_state = c.state == .established or c.state == .close_wait;
    return .{
        .readable = c.rx_len > 0 or c.peer_fin or failed,
        .writable = (writable_state and !c.fin_queued and c.tx.len - c.tx_len >= 4096) or failed,
        .failed = failed,
        .hangup = failed or (c.peer_fin and c.fin_queued) or (!connected and c.state == .closed),
        .read_hangup = c.peer_fin,
    };
}

pub fn keepaliveLocked(c: *Tcb, on: bool) void {
    c.keepalive = on;
    c.keepalive_at = 0;
    c.keepalive_sent = 0;
}

pub fn activeCount() usize {
    const irq = net.acquire();
    defer net.release(irq);
    var n: usize = 0;
    var cursor = connections;
    while (cursor) |c| : (cursor = c.next) n += 1;
    return n;
}

// ── The original native interface (syscalls 97-100) ─────────────────────────
//
// Programs from before BSD sockets hold small connection numbers owned by
// their process. Each number names a connection here with a generation, so a
// wait whose connection another thread closed notices instead of reading a
// reused slot. Waits sleep on the connection's channel.

const LEGACY_SLOTS = 16;
const Legacy = struct { tcb: ?*Tcb = null, owner: u32 = 0, generation: u32 = 0 };
var legacy: [LEGACY_SLOTS]Legacy = [_]Legacy{.{}} ** LEGACY_SLOTS;

fn legacyLocked(index: usize, generation: ?u32) ?*Tcb {
    if (index >= LEGACY_SLOTS) return null;
    const slot = &legacy[index];
    const c = slot.tcb orelse return null;
    if (generation) |g| if (slot.generation != g) return null;
    return c;
}

fn legacyChannel(index: usize) usize {
    return @intFromPtr(&legacy[index]);
}

/// Wait for `ready` on a legacy connection, up to `deadline_us`. Returns
/// false on timeout, interruption or when the slot was closed.
fn legacyWait(index: usize, generation: u32, deadline_us: u64, comptime ready: fn (*Tcb) bool) bool {
    while (true) {
        sched.prepareWait(legacyChannel(index));
        {
            const irq = net.acquire();
            defer net.release(irq);
            const c = legacyLocked(index, generation) orelse {
                sched.cancelWait();
                return false;
            };
            if (ready(c)) {
                sched.cancelWait();
                return true;
            }
        }
        const now = tsc.microsSinceBoot();
        if (now >= deadline_us or sched.interruptPending()) {
            sched.cancelWait();
            return false;
        }
        sched.commitWaitTimeout(@max((deadline_us - now) / 1000, 1));
    }
}

/// Active open; waits until the handshake completes or times out.
pub fn connect(dst_ip: net.Ipv4Addr, dst_port: u16, timeout_ms: u64, owner_tid: u32) Error!usize {
    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    if (net.isLoopback(dst_ip)) return Error.Unreachable;
    const c = try create();
    var index: usize = undefined;
    var generation: u32 = undefined;
    {
        const irq = net.acquire();
        defer net.release(irq);
        const free = for (&legacy, 0..) |*slot, i| {
            if (slot.tcb == null) break i;
        } else {
            destroyUnused(c);
            return Error.NoSockets;
        };
        legacy[free] = .{ .tcb = c, .owner = owner_tid, .generation = legacy[free].generation +% 1 };
        index = free;
        generation = legacy[free].generation;
        c.wake_channel = legacyChannel(free);
        connectLocked(c, dst_ip, dst_port, 0) catch |e| {
            legacy[free].tcb = null;
            destroyUnused(c);
            return e;
        };
    }
    const done = legacyWait(index, generation, deadline, struct {
        fn f(t: *Tcb) bool {
            return t.state != .syn_sent;
        }
    }.f);
    const irq = net.acquire();
    defer net.release(irq);
    const live = legacyLocked(index, generation) orelse return Error.NotConnected;
    if (done and live.state == .established) return index;
    const why = live.failure orelse Error.Timeout;
    legacy[index].tcb = null;
    detachLocked(live);
    if (live.state != .closed) abortLocked(live);
    return why;
}

pub fn ownedBy(index: usize, owner_tid: u32) bool {
    const irq = net.acquire();
    defer net.release(irq);
    if (index >= LEGACY_SLOTS or legacy[index].tcb == null) return false;
    return legacy[index].owner == owner_tid;
}

/// Queue data, waiting up to 3 s for room in the send ring.
pub fn send(index: usize, data: []const u8) Error!usize {
    const deadline = tsc.microsSinceBoot() + 3_000_000;
    var generation: u32 = undefined;
    {
        const irq = net.acquire();
        defer net.release(irq);
        if (index >= LEGACY_SLOTS or legacy[index].tcb == null) return Error.NotConnected;
        generation = legacy[index].generation;
    }
    while (true) {
        {
            const irq = net.acquire();
            defer net.release(irq);
            const c = legacyLocked(index, generation) orelse return Error.NotConnected;
            if (c.failure) |why| return why;
            if (c.state != .established and c.state != .close_wait) return Error.NotConnected;
            const n = writeLocked(c, data);
            if (n > 0) return n;
        }
        if (!legacyWait(index, generation, deadline, struct {
            fn f(t: *Tcb) bool {
                return t.tx.len - t.tx_len > 0 or t.failure != null;
            }
        }.f)) return Error.Timeout;
    }
}

/// Read what has arrived, waiting up to `timeout_ms`; 0 at end of stream or
/// on timeout.
pub fn recv(index: usize, out: []u8, timeout_ms: u64) Error!usize {
    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    var generation: u32 = undefined;
    {
        const irq = net.acquire();
        defer net.release(irq);
        if (index >= LEGACY_SLOTS or legacy[index].tcb == null) return Error.NotConnected;
        generation = legacy[index].generation;
    }
    _ = legacyWait(index, generation, deadline, struct {
        fn f(t: *Tcb) bool {
            return t.rx_len > 0 or t.peer_fin or t.failure != null;
        }
    }.f);
    const irq = net.acquire();
    defer net.release(irq);
    const c = legacyLocked(index, generation) orelse return Error.NotConnected;
    const n = readLocked(c, out, true);
    if (n > 0) return n;
    if (c.failure) |why| return why;
    return 0;
}

/// Close gracefully in the background and free the number now.
pub fn close(index: usize) void {
    const irq = net.acquire();
    defer net.release(irq);
    if (index >= LEGACY_SLOTS) return;
    const c = legacy[index].tcb orelse return;
    legacy[index].tcb = null;
    sched.wakeChannel(legacyChannel(index));
    detachLocked(c);
}

pub fn state(index: usize) State {
    const irq = net.acquire();
    defer net.release(irq);
    const c = legacyLocked(index, null) orelse return .closed;
    return c.state;
}

/// A process exiting cannot spend time on graceful handshakes: reset every
/// connection it owned through the legacy numbers.
pub fn abortOwnedBy(owner_tid: u32) void {
    if (owner_tid == 0) return;
    const irq = net.acquire();
    defer net.release(irq);
    for (&legacy, 0..) |*slot, i| {
        const c = slot.tcb orelse continue;
        if (slot.owner != owner_tid) continue;
        slot.tcb = null;
        sched.wakeChannel(legacyChannel(i));
        abortLocked(c);
        detachLocked(c);
    }
}
