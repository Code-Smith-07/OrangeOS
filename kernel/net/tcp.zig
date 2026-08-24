//! TCP — client side.
//!
//! A connection is a state machine over an unreliable channel, and almost all
//! of the difficulty is in the arithmetic rather than the states. Sequence
//! numbers are 32-bit and wrap, so every comparison must be done modulo 2^32:
//! `a < b` is wrong and `(a - b)` interpreted as signed is right. Getting that
//! wrong produces a connection that works until it has transferred four
//! gigabytes, which is to say one that appears to work.
//!
//! What this implements: active open, in-order data transfer with
//! acknowledgement, retransmission on timeout, and orderly close.
//!
//! What it deliberately does not: out-of-order reassembly (segments arriving
//! ahead of the window are dropped and the peer retransmits), congestion
//! control (the window is fixed), and passive open. Each of those is a real
//! omission rather than a hidden one, and each is honest about costing
//! throughput rather than correctness.

const std = @import("std");
const net = @import("net.zig");
const console = @import("../console.zig");
const tsc = @import("../time/tsc.zig");

pub const Error = error{
    NoSockets,
    NotConnected,
    Refused,
    Timeout,
    TooLarge,
    Reset,
};

const FLAG_FIN: u8 = 1 << 0;
const FLAG_SYN: u8 = 1 << 1;
const FLAG_RST: u8 = 1 << 2;
const FLAG_PSH: u8 = 1 << 3;
const FLAG_ACK: u8 = 1 << 4;

const PROTO_TCP: u8 = 6;

const MSS: usize = 1400;
const RX_BUFFER: usize = 8192;
const TX_BUFFER: usize = 2048;
const MAX_CONNECTIONS = 4;

const RETRANSMIT_US: u64 = 500_000;
const MAX_RETRIES: u32 = 6;

pub const State = enum(u8) {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
    time_wait,
};

const Tcb = struct {
    used: bool = false,
    state: State = .closed,

    local_port: u16 = 0,
    remote_ip: net.Ipv4Addr = .{ 0, 0, 0, 0 },
    remote_port: u16 = 0,

    /// Send sequence space.
    snd_una: u32 = 0, // oldest unacknowledged
    snd_nxt: u32 = 0, // next to send
    /// Receive sequence space.
    rcv_nxt: u32 = 0, // next expected

    /// Data received in order and not yet read by the application.
    rx: [RX_BUFFER]u8 = undefined,
    rx_len: usize = 0,

    /// The last segment sent, kept for retransmission.
    tx: [TX_BUFFER]u8 = undefined,
    tx_len: usize = 0,
    tx_seq: u32 = 0,
    tx_flags: u8 = 0,
    tx_time: u64 = 0,
    retries: u32 = 0,

    peer_closed: bool = false,
    reset: bool = false,
};

var conns: [MAX_CONNECTIONS]Tcb = [_]Tcb{.{}} ** MAX_CONNECTIONS;
var next_port: u16 = 32768;
var isn_counter: u32 = 0x1234_5678;

// ── Sequence arithmetic ─────────────────────────────────────────────────────

/// True if `a` is at or after `b` in sequence space. Subtracting and reading
/// the result as signed is what makes this correct across the wrap point.
inline fn seqGE(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

inline fn seqGT(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
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

/// Same pseudo-header as UDP: addresses and protocol are covered so a segment
/// delivered to the wrong host fails rather than being accepted.
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

fn transmit(c: *Tcb, flags: u8, seq: u32, payload: []const u8) void {
    var seg: [20 + MSS]u8 = undefined;

    putBe16(&seg, 0, c.local_port);
    putBe16(&seg, 2, c.remote_port);
    putBe32(&seg, 4, seq);
    putBe32(&seg, 8, if (flags & FLAG_ACK != 0) c.rcv_nxt else 0);
    seg[12] = 5 << 4; // data offset: 5 words, no options
    seg[13] = flags;
    putBe16(&seg, 14, @intCast(RX_BUFFER - c.rx_len)); // advertised window
    putBe16(&seg, 16, 0); // checksum
    putBe16(&seg, 18, 0); // urgent pointer

    const n = @min(payload.len, MSS);
    @memcpy(seg[20 .. 20 + n], payload[0..n]);
    const total = 20 + n;

    const sum = tcpChecksum(net.local_ip, c.remote_ip, seg[0..total]);
    putBe16(&seg, 16, sum);

    net.sendRaw(c.remote_ip, PROTO_TCP, seg[0..total]) catch {};
}

/// Send and remember, so a lost segment can be sent again.
fn transmitTracked(c: *Tcb, flags: u8, payload: []const u8) void {
    const n = @min(payload.len, @min(MSS, TX_BUFFER));
    @memcpy(c.tx[0..n], payload[0..n]);
    c.tx_len = n;
    c.tx_seq = c.snd_nxt;
    c.tx_flags = flags;
    c.tx_time = tsc.microsSinceBoot();
    c.retries = 0;

    transmit(c, flags, c.snd_nxt, payload[0..n]);

    // SYN and FIN each consume one sequence number even with no data.
    var consumed: u32 = @intCast(n);
    if (flags & FLAG_SYN != 0) consumed += 1;
    if (flags & FLAG_FIN != 0) consumed += 1;
    c.snd_nxt +%= consumed;
}

fn maybeRetransmit(c: *Tcb) void {
    if (c.tx_len == 0 and c.tx_flags & (FLAG_SYN | FLAG_FIN) == 0) return;
    if (seqGE(c.snd_una, c.snd_nxt)) return; // everything acknowledged

    const now = tsc.microsSinceBoot();
    if (now - c.tx_time < RETRANSMIT_US) return;
    if (c.retries >= MAX_RETRIES) return;

    c.retries += 1;
    c.tx_time = now;
    transmit(c, c.tx_flags, c.tx_seq, c.tx[0..c.tx_len]);
}

// ── Receive ─────────────────────────────────────────────────────────────────

fn findConn(local_port: u16, remote_ip: net.Ipv4Addr, remote_port: u16) ?*Tcb {
    for (&conns) |*c| {
        if (!c.used) continue;
        if (c.local_port != local_port or c.remote_port != remote_port) continue;
        if (!std.mem.eql(u8, &c.remote_ip, &remote_ip)) continue;
        return c;
    }
    return null;
}

pub fn input(segment: []const u8, src_ip: net.Ipv4Addr) void {
    if (segment.len < 20) return;

    const src_port = be16(segment, 0);
    const dst_port = be16(segment, 2);
    const seq = be32(segment, 4);
    const ack = be32(segment, 8);
    const offset: usize = @as(usize, segment[12] >> 4) * 4;
    const flags = segment[13];

    if (offset < 20 or offset > segment.len) return;
    const data = segment[offset..];

    const c = findConn(dst_port, src_ip, src_port) orelse return;

    if (flags & FLAG_RST != 0) {
        c.reset = true;
        c.state = .closed;
        return;
    }

    switch (c.state) {
        .syn_sent => {
            if (flags & FLAG_SYN == 0 or flags & FLAG_ACK == 0) return;
            if (ack != c.snd_nxt) return;

            c.rcv_nxt = seq +% 1;
            c.snd_una = ack;
            c.state = .established;
            c.tx_len = 0;
            c.tx_flags = 0;
            transmit(c, FLAG_ACK, c.snd_nxt, &.{});
        },

        .established, .fin_wait_1, .fin_wait_2 => {
            if (flags & FLAG_ACK != 0 and seqGT(ack, c.snd_una)) {
                c.snd_una = ack;
                c.tx_len = 0;
            }

            // In-order data only. A segment ahead of the window is dropped and
            // the peer will send it again; one behind is a duplicate.
            if (data.len > 0 and seq == c.rcv_nxt) {
                const space = RX_BUFFER - c.rx_len;
                const n = @min(data.len, space);
                @memcpy(c.rx[c.rx_len .. c.rx_len + n], data[0..n]);
                c.rx_len += n;
                c.rcv_nxt +%= @intCast(n);
                transmit(c, FLAG_ACK, c.snd_nxt, &.{});
            } else if (data.len > 0) {
                // Re-acknowledge what we do have, so the peer resends.
                transmit(c, FLAG_ACK, c.snd_nxt, &.{});
            }

            if (flags & FLAG_FIN != 0 and seq +% @as(u32, @intCast(data.len)) == c.rcv_nxt) {
                c.rcv_nxt +%= 1;
                c.peer_closed = true;
                transmit(c, FLAG_ACK, c.snd_nxt, &.{});

                c.state = switch (c.state) {
                    .established => .close_wait,
                    .fin_wait_1, .fin_wait_2 => .time_wait,
                    else => c.state,
                };
            } else if (c.state == .fin_wait_1 and seqGE(c.snd_una, c.snd_nxt)) {
                c.state = .fin_wait_2;
            }
        },

        .last_ack => {
            if (flags & FLAG_ACK != 0) c.state = .closed;
        },

        else => {},
    }
}

// ── Public API ──────────────────────────────────────────────────────────────

fn allocate() ?*Tcb {
    for (&conns) |*c| {
        if (c.used) continue;
        c.* = .{ .used = true };
        return c;
    }
    return null;
}

pub fn indexOf(c: *Tcb) usize {
    return (@intFromPtr(c) - @intFromPtr(&conns[0])) / @sizeOf(Tcb);
}

fn get(index: usize) ?*Tcb {
    if (index >= MAX_CONNECTIONS or !conns[index].used) return null;
    return &conns[index];
}

/// Active open. Blocks until the handshake completes or times out.
pub fn connect(dst_ip: net.Ipv4Addr, dst_port: u16, timeout_ms: u64) Error!usize {
    const c = allocate() orelse return Error.NoSockets;
    errdefer c.used = false;

    c.local_port = next_port;
    next_port +%= 1;
    if (next_port < 32768) next_port = 32768;

    c.remote_ip = dst_ip;
    c.remote_port = dst_port;

    isn_counter +%= 0x9E37_79B9;
    c.snd_una = isn_counter;
    c.snd_nxt = isn_counter;
    c.state = .syn_sent;

    transmitTracked(c, FLAG_SYN, &.{});

    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    while (tsc.microsSinceBoot() < deadline) {
        net.poll();
        maybeRetransmit(c);

        if (c.reset) return Error.Refused;
        if (c.state == .established) return indexOf(c);
        asm volatile ("pause");
    }

    c.used = false;
    return Error.Timeout;
}

pub fn send(index: usize, data: []const u8) Error!usize {
    const c = get(index) orelse return Error.NotConnected;
    if (c.reset) return Error.Reset;
    if (c.state != .established and c.state != .close_wait) return Error.NotConnected;

    const n = @min(data.len, MSS);
    transmitTracked(c, FLAG_ACK | FLAG_PSH, data[0..n]);

    // Wait for the acknowledgement before returning, so a caller that sends in
    // a loop cannot outrun the single retransmission slot.
    const deadline = tsc.microsSinceBoot() + 3_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        net.poll();
        maybeRetransmit(c);
        if (c.reset) return Error.Reset;
        if (seqGE(c.snd_una, c.snd_nxt)) return n;
        asm volatile ("pause");
    }
    return Error.Timeout;
}

/// Read whatever has arrived, waiting up to `timeout_ms` for something.
pub fn recv(index: usize, out: []u8, timeout_ms: u64) Error!usize {
    const c = get(index) orelse return Error.NotConnected;

    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    while (true) {
        net.poll();
        maybeRetransmit(c);

        if (c.rx_len > 0) {
            const n = @min(out.len, c.rx_len);
            @memcpy(out[0..n], c.rx[0..n]);
            // Shift the remainder down. A ring would avoid the copy; at these
            // sizes the simpler invariant is worth more than the memmove.
            const left = c.rx_len - n;
            if (left > 0) std.mem.copyForwards(u8, c.rx[0..left], c.rx[n..c.rx_len]);
            c.rx_len = left;
            return n;
        }

        if (c.reset) return Error.Reset;
        if (c.peer_closed) return 0; // orderly end of stream
        if (tsc.microsSinceBoot() >= deadline) return 0;
        asm volatile ("pause");
    }
}

pub fn close(index: usize) void {
    const c = get(index) orelse return;

    if (c.state == .established) {
        transmitTracked(c, FLAG_ACK | FLAG_FIN, &.{});
        c.state = .fin_wait_1;
    } else if (c.state == .close_wait) {
        transmitTracked(c, FLAG_ACK | FLAG_FIN, &.{});
        c.state = .last_ack;
    }

    // Give the close a moment to complete, then release regardless. A proper
    // TIME_WAIT holds the port for twice the segment lifetime; nothing here
    // reuses ports fast enough for that to matter yet.
    const deadline = tsc.microsSinceBoot() + 500_000;
    while (tsc.microsSinceBoot() < deadline and c.state != .closed) {
        net.poll();
        asm volatile ("pause");
    }

    c.used = false;
    c.state = .closed;
}

pub fn state(index: usize) State {
    const c = get(index) orelse return .closed;
    return c.state;
}
