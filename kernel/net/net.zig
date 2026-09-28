//! Network stack — Ethernet, ARP, IPv4, ICMP.
//!
//! Everything on the wire is big-endian and nothing is aligned, so all header
//! access goes through explicit byte reads rather than struct overlays. A
//! packed struct would be shorter and would break the first time a header
//! landed at an odd offset.
//!
//! ── Concurrency ─────────────────────────────────────────────────────────────
//!
//! Any CPU may be in a network syscall, and threads of one program may be in
//! several at once. One lock covers every piece of network state: the NIC
//! rings, the receive buffer, the ARP cache, sockets, ICMP reply records and
//! the TCP connection table. It is held only for bounded steps — drain the
//! receive ring, send a frame, update a table. Waits never hold it: they poll
//! under the lock, drop it and sleep between polls (`waitStep`). So no CPU
//! spins for seconds with interrupts masked, a TLB shootdown to a waiting CPU
//! is acknowledged, and a program's exit interrupts its network waits.
//!
//! Functions named `...Locked` expect the lock held. Blocking ARP resolution
//! happens only at the start of an operation, outside the lock; sends made
//! with the lock held use the cache and, on a miss, request the address and
//! report NoRoute (TCP simply retransmits).

const std = @import("std");
const e1000 = @import("../drivers/net/e1000.zig");
const console = @import("../console.zig");
const tsc = @import("../time/tsc.zig");
const spinlock = @import("../sync/spinlock.zig");
const sched = @import("../sched/sched.zig");

var lock: spinlock.SpinLock = .{};

pub fn acquire() spinlock.IrqState {
    return spinlock.acquireIrqSave(&lock);
}

pub fn release(state: spinlock.IrqState) void {
    spinlock.releaseIrqRestore(&lock, state);
}

/// Pause between polls of a network wait, without the lock. False when the
/// caller should give up: its deadline passed or its program is exiting.
/// Before the scheduler runs (DHCP at boot) this busy-waits instead.
pub fn waitStep(deadline_us: u64) bool {
    if (tsc.microsSinceBoot() >= deadline_us or sched.killPending()) return false;
    sched.sleepMs(1);
    return !sched.killPending();
}

pub const Error = error{
    NoDevice,
    Timeout,
    TooLarge,
    NoRoute,
} || e1000.Error;

pub const MacAddr = [6]u8;
pub const Ipv4Addr = [4]u8;

pub const BROADCAST: MacAddr = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

/// QEMU's user-mode network: the guest is .15 and the gateway is .2.
/// DHCP replaces these once there is a client to run it.
pub var local_ip: Ipv4Addr = .{ 10, 0, 2, 15 };
pub var gateway_ip: Ipv4Addr = .{ 10, 0, 2, 2 };
pub var netmask: Ipv4Addr = .{ 255, 255, 255, 0 };

const ETH_HEADER_LEN: usize = 14;
const ETHERTYPE_IPV4: u16 = 0x0800;
const ETHERTYPE_ARP: u16 = 0x0806;

const PROTO_ICMP: u8 = 1;
const PROTO_UDP: u8 = 17;
const PROTO_TCP: u8 = 6;

// ── Byte order helpers ──────────────────────────────────────────────────────

inline fn be16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}

inline fn putBe16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v >> 8);
    buf[off + 1] = @truncate(v);
}

// ── Ethernet ────────────────────────────────────────────────────────────────

fn writeEthHeader(buf: []u8, dst: MacAddr, ethertype: u16) void {
    const src = e1000.macAddress();
    @memcpy(buf[0..6], &dst);
    @memcpy(buf[6..12], &src);
    putBe16(buf, 12, ethertype);
}

// ── ARP ─────────────────────────────────────────────────────────────────────

const ARP_REQUEST: u16 = 1;
const ARP_REPLY: u16 = 2;

const CACHE_SIZE = 8;

const ArpEntry = struct {
    ip: Ipv4Addr = .{ 0, 0, 0, 0 },
    mac: MacAddr = .{ 0, 0, 0, 0, 0, 0 },
    valid: bool = false,
};

var arp_cache: [CACHE_SIZE]ArpEntry = [_]ArpEntry{.{}} ** CACHE_SIZE;
var arp_next: usize = 0;

fn arpLookup(ip: Ipv4Addr) ?MacAddr {
    for (arp_cache) |e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    }
    return null;
}

fn arpInsert(ip: Ipv4Addr, mac: MacAddr) void {
    for (&arp_cache) |*e| {
        if (e.valid and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            return;
        }
    }
    arp_cache[arp_next] = .{ .ip = ip, .mac = mac, .valid = true };
    arp_next = (arp_next + 1) % CACHE_SIZE;
}

fn sendArpRequest(target: Ipv4Addr) Error!void {
    var frame: [42]u8 = undefined;
    @memset(&frame, 0);

    writeEthHeader(&frame, BROADCAST, ETHERTYPE_ARP);

    putBe16(&frame, 14, 1); // hardware type: Ethernet
    putBe16(&frame, 16, ETHERTYPE_IPV4);
    frame[18] = 6; // hardware address length
    frame[19] = 4; // protocol address length
    putBe16(&frame, 20, ARP_REQUEST);

    const src = e1000.macAddress();
    @memcpy(frame[22..28], &src);
    @memcpy(frame[28..32], &local_ip);
    // Target hardware address stays zero — that is what we are asking for.
    @memcpy(frame[38..42], &target);

    try e1000.send(&frame);
}

fn handleArp(frame: []const u8) void {
    if (frame.len < 42) return;

    const op = be16(frame, 20);
    var sender_ip: Ipv4Addr = undefined;
    var sender_mac: MacAddr = undefined;
    @memcpy(&sender_mac, frame[22..28]);
    @memcpy(&sender_ip, frame[28..32]);

    // Learn from any ARP traffic, request or reply. A host that ARPs us is
    // about to be talked to anyway.
    arpInsert(sender_ip, sender_mac);
    flushPending(sender_ip, sender_mac);

    if (op != ARP_REQUEST) return;

    var target_ip: Ipv4Addr = undefined;
    @memcpy(&target_ip, frame[38..42]);
    if (!std.mem.eql(u8, &target_ip, &local_ip)) return;

    var reply: [42]u8 = undefined;
    @memset(&reply, 0);
    writeEthHeader(&reply, sender_mac, ETHERTYPE_ARP);
    putBe16(&reply, 14, 1);
    putBe16(&reply, 16, ETHERTYPE_IPV4);
    reply[18] = 6;
    reply[19] = 4;
    putBe16(&reply, 20, ARP_REPLY);

    const src = e1000.macAddress();
    @memcpy(reply[22..28], &src);
    @memcpy(reply[28..32], &local_ip);
    @memcpy(reply[32..38], &sender_mac);
    @memcpy(reply[38..42], &sender_ip);

    e1000.send(&reply) catch {};
}

/// Resolve an address, re-sending requests until an answer arrives. Called
/// without the lock, at the start of an operation.
pub fn resolve(ip: Ipv4Addr, timeout_ms: u64) ?MacAddr {
    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    const interval = @max(timeout_ms * 1000 / 4, 1000);
    var next_request: u64 = 0;
    while (true) {
        const state = acquire();
        pollLocked();
        if (arpLookup(ip)) |m| {
            release(state);
            return m;
        }
        const now = tsc.microsSinceBoot();
        if (now >= next_request) {
            sendArpRequest(ip) catch {};
            next_request = now + interval;
        }
        release(state);
        if (!waitStep(deadline)) return null;
    }
}

/// The on-link address a packet for `dst` must be sent to.
pub fn nextHop(dst: Ipv4Addr) Ipv4Addr {
    return if (sameSubnet(dst)) dst else gateway_ip;
}

// ── IPv4 ────────────────────────────────────────────────────────────────────

var ip_id: u16 = 1;

/// One's-complement sum, as every IP checksum uses.
fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

/// Build an IPv4 packet into `buf` after the Ethernet header.
/// Returns the total frame length.
fn buildIpv4(buf: []u8, dst_mac: MacAddr, dst_ip: Ipv4Addr, proto: u8, payload: []const u8) usize {
    writeEthHeader(buf, dst_mac, ETHERTYPE_IPV4);

    const ip = buf[ETH_HEADER_LEN..];
    const total_len: u16 = @intCast(20 + payload.len);

    ip[0] = 0x45; // version 4, header length 5 words
    ip[1] = 0; // DSCP/ECN
    putBe16(ip, 2, total_len);
    putBe16(ip, 4, ip_id);
    ip_id +%= 1;
    putBe16(ip, 6, 0); // no fragmentation
    ip[8] = 64; // TTL
    ip[9] = proto;
    putBe16(ip, 10, 0); // checksum, filled below
    @memcpy(ip[12..16], &local_ip);
    @memcpy(ip[16..20], &dst_ip);

    const sum = checksum(ip[0..20]);
    putBe16(ip, 10, sum);

    @memcpy(ip[20 .. 20 + payload.len], payload);
    return ETH_HEADER_LEN + 20 + payload.len;
}

// ── ICMP ────────────────────────────────────────────────────────────────────

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;

/// Recent echo replies, matched by (identifier, sequence). Each ping uses a
/// fresh identifier, so concurrent pings never consume each other's replies.
const EchoReply = struct { id: u16 = 0, seq: u16 = 0, valid: bool = false };
var echo_replies: [16]EchoReply = [_]EchoReply{.{}} ** 16;
var echo_next: usize = 0;
var echo_id: u16 = 0x4F53; // "OS"

fn takeEchoReplyLocked(id: u16, seq: u16) bool {
    for (&echo_replies) |*r| {
        if (r.valid and r.id == id and r.seq == seq) {
            r.valid = false;
            return true;
        }
    }
    return false;
}

fn handleIcmp(ip_payload: []const u8, src_ip: Ipv4Addr) void {
    if (ip_payload.len < 8) return;

    switch (ip_payload[0]) {
        ICMP_ECHO_REPLY => {
            echo_replies[echo_next] = .{ .id = be16(ip_payload, 4), .seq = be16(ip_payload, 6), .valid = true };
            echo_next = (echo_next + 1) % echo_replies.len;
        },
        ICMP_ECHO_REQUEST => {
            // Answer pings addressed to us.
            const dst_mac = arpLookup(src_ip) orelse return;

            var frame: [1518]u8 = undefined;
            const n = @min(ip_payload.len, frame.len - ETH_HEADER_LEN - 20);

            var payload: [1024]u8 = undefined;
            const len = @min(n, payload.len);
            @memcpy(payload[0..len], ip_payload[0..len]);
            payload[0] = ICMP_ECHO_REPLY;
            payload[2] = 0;
            payload[3] = 0;
            const sum = checksum(payload[0..len]);
            putBe16(&payload, 2, sum);

            const total = buildIpv4(&frame, dst_mac, src_ip, PROTO_ICMP, payload[0..len]);
            e1000.send(frame[0..total]) catch {};
        },
        else => {},
    }
}

/// Send an echo request and wait for the reply. Returns the round trip in
/// microseconds, or null on timeout. Replies are observed between 1 ms
/// sleeps, so the figure is rounded up to that granularity.
pub fn ping(dst_ip: Ipv4Addr, seq: u16, timeout_ms: u64) ?u64 {
    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    _ = resolve(nextHop(dst_ip), @min(timeout_ms, 1000)) orelse return null;

    const start = tsc.microsSinceBoot();
    var id: u16 = undefined;
    {
        const state = acquire();
        defer release(state);
        echo_id +%= 1;
        id = echo_id;

        var payload: [40]u8 = undefined;
        @memset(&payload, 0);
        payload[0] = ICMP_ECHO_REQUEST;
        payload[1] = 0;
        putBe16(&payload, 2, 0); // checksum
        putBe16(&payload, 4, id);
        putBe16(&payload, 6, seq);
        for (payload[8..], 0..) |*b, i| b.* = @truncate(i);
        const sum = checksum(&payload);
        putBe16(&payload, 2, sum);
        sendRawLocked(dst_ip, PROTO_ICMP, &payload) catch return null;
    }

    while (true) {
        const state = acquire();
        pollLocked();
        const answered = takeEchoReplyLocked(id, seq);
        release(state);
        if (answered) return tsc.microsSinceBoot() - start;
        if (!waitStep(deadline)) return null;
    }
}

// ── UDP ─────────────────────────────────────────────────────────────────────

pub const MAX_DATAGRAM: usize = 1024;

pub const Datagram = struct {
    src_ip: Ipv4Addr,
    src_port: u16,
    len: usize,
    data: [MAX_DATAGRAM]u8,
};

const MAX_SOCKETS = 8;

const Socket = struct {
    used: bool = false,
    owner_tid: u32 = 0,
    port: u16 = 0,
    /// One-deep receive queue. A datagram arriving while one is pending
    /// replaces it: for the request/response traffic this serves, the newest
    /// answer is the interesting one.
    pending: bool = false,
    dgram: Datagram = undefined,
};

var sockets: [MAX_SOCKETS]Socket = [_]Socket{.{}} ** MAX_SOCKETS;
var ephemeral_next: u16 = 49152;

pub fn socketOpen(port: u16) ?usize {
    return socketOpenOwned(port, 0);
}

/// A nonzero owner is a user process; zero is reserved for kernel DNS/DHCP.
pub fn socketOpenOwned(port: u16, owner_tid: u32) ?usize {
    const state = acquire();
    defer release(state);
    var chosen = port;
    if (chosen == 0) {
        chosen = ephemeral_next;
        ephemeral_next +%= 1;
        if (ephemeral_next < 49152) ephemeral_next = 49152;
    }

    for (&sockets, 0..) |*s, i| {
        if (s.used) continue;
        s.* = .{ .used = true, .owner_tid = owner_tid, .port = chosen };
        return i;
    }
    return null;
}

pub fn socketClose(index: usize) void {
    if (index >= MAX_SOCKETS) return;
    const state = acquire();
    defer release(state);
    sockets[index].used = false;
}

pub fn socketOwnedBy(index: usize, owner_tid: u32) bool {
    const state = acquire();
    defer release(state);
    return index < MAX_SOCKETS and sockets[index].used and sockets[index].owner_tid == owner_tid;
}

pub fn socketCloseOwnedBy(owner_tid: u32) void {
    if (owner_tid == 0) return;
    const state = acquire();
    defer release(state);
    for (&sockets) |*s| {
        if (s.used and s.owner_tid == owner_tid) s.used = false;
    }
}

pub fn socketPort(index: usize) u16 {
    const state = acquire();
    defer release(state);
    if (index >= MAX_SOCKETS or !sockets[index].used) return 0;
    return sockets[index].port;
}

/// UDP's checksum covers a pseudo-header of addresses and protocol as well as
/// the datagram itself, so a packet delivered to the wrong host or protocol
/// fails the check rather than being silently accepted.
fn udpChecksum(src: Ipv4Addr, dst: Ipv4Addr, udp: []const u8) u16 {
    var sum: u32 = 0;

    sum += (@as(u32, src[0]) << 8) | src[1];
    sum += (@as(u32, src[2]) << 8) | src[3];
    sum += (@as(u32, dst[0]) << 8) | dst[1];
    sum += (@as(u32, dst[2]) << 8) | dst[3];
    sum += PROTO_UDP;
    sum += @as(u32, @intCast(udp.len));

    var i: usize = 0;
    while (i + 1 < udp.len) : (i += 2) {
        sum += (@as(u32, udp[i]) << 8) | udp[i + 1];
    }
    if (i < udp.len) sum += @as(u32, udp[i]) << 8;

    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    const result: u16 = @truncate(~sum);
    // Zero means "no checksum" on the wire, so a computed zero is sent as all
    // ones, which is numerically equivalent in one's complement.
    return if (result == 0) 0xFFFF else result;
}

pub fn sendTo(index: usize, dst_ip: Ipv4Addr, dst_port: u16, payload: []const u8) Error!void {
    if (payload.len > MAX_DATAGRAM) return Error.TooLarge;
    const broadcast = std.mem.eql(u8, &dst_ip, &BROADCAST_IP);
    // Resolve before taking the lock; the send below only reads the cache.
    if (!broadcast) _ = resolve(nextHop(dst_ip), 1000) orelse return Error.NoRoute;

    const state = acquire();
    defer release(state);
    if (index >= MAX_SOCKETS or !sockets[index].used) return Error.NoRoute;
    const dst_mac = if (broadcast)
        BROADCAST
    else
        arpLookup(nextHop(dst_ip)) orelse return Error.NoRoute;

    var udp: [8 + MAX_DATAGRAM]u8 = undefined;
    putBe16(&udp, 0, sockets[index].port);
    putBe16(&udp, 2, dst_port);
    putBe16(&udp, 4, @intCast(8 + payload.len));
    putBe16(&udp, 6, 0);
    @memcpy(udp[8 .. 8 + payload.len], payload);

    const total_udp = 8 + payload.len;
    const sum = udpChecksum(local_ip, dst_ip, udp[0..total_udp]);
    putBe16(&udp, 6, sum);

    var frame: [1518]u8 = undefined;
    const n = buildIpv4(&frame, dst_mac, dst_ip, PROTO_UDP, udp[0..total_udp]);
    try e1000.send(frame[0..n]);
}

/// Whether an original-interface UDP slot holds `port`. Caller holds the
/// network lock.
pub fn legacyUdpPortBusyLocked(port: u16) bool {
    for (&sockets) |*s| {
        if (s.used and s.port == port) return true;
    }
    return false;
}

/// Send one datagram from `src_port`. An unresolved next hop holds it until
/// the address is known (NoRoute is reported, the datagram is not lost).
/// Caller holds the network lock.
pub fn sendUdpLocked(src_port: u16, dst_ip: Ipv4Addr, dst_port: u16, payload: []const u8) Error!void {
    if (payload.len > 1500 - 20 - 8) return Error.TooLarge;
    var udp: [1500 - 20]u8 = undefined;
    putBe16(&udp, 0, src_port);
    putBe16(&udp, 2, dst_port);
    putBe16(&udp, 4, @intCast(8 + payload.len));
    putBe16(&udp, 6, 0);
    @memcpy(udp[8 .. 8 + payload.len], payload);
    const total = 8 + payload.len;
    putBe16(&udp, 6, udpChecksum(local_ip, dst_ip, udp[0..total]));
    if (std.mem.eql(u8, &dst_ip, &BROADCAST_IP)) {
        var frame: [1600]u8 = undefined;
        const n = buildIpv4(&frame, BROADCAST, dst_ip, PROTO_UDP, udp[0..total]);
        return e1000.send(frame[0..n]);
    }
    return sendRawLocked(dst_ip, PROTO_UDP, udp[0..total]);
}

/// Drain the receive ring, then take a pending datagram into `out`. The copy
/// is made under the lock: the socket's buffer is overwritten by the next
/// arrival, possibly on another CPU.
pub fn pollReceive(index: usize, out: *Datagram) bool {
    const state = acquire();
    defer release(state);
    pollLocked();
    if (index >= MAX_SOCKETS or !sockets[index].used) return false;
    if (!sockets[index].pending) return false;
    sockets[index].pending = false;
    out.src_ip = sockets[index].dgram.src_ip;
    out.src_port = sockets[index].dgram.src_port;
    out.len = sockets[index].dgram.len;
    @memcpy(out.data[0..out.len], sockets[index].dgram.data[0..out.len]);
    return true;
}

pub const BROADCAST_IP: Ipv4Addr = .{ 255, 255, 255, 255 };

fn sameSubnet(ip: Ipv4Addr) bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if ((ip[i] & netmask[i]) != (local_ip[i] & netmask[i])) return false;
    }
    return true;
}

fn handleUdp(payload: []const u8, src_ip: Ipv4Addr) void {
    if (payload.len < 8) return;

    const src_port = be16(payload, 0);
    const dst_port = be16(payload, 2);
    const length = be16(payload, 4);
    if (length < 8 or length > payload.len) return;

    const data = payload[8..length];

    for (&sockets) |*s| {
        if (!s.used or s.port != dst_port) continue;
        s.dgram.src_ip = src_ip;
        s.dgram.src_port = src_port;
        s.dgram.len = @min(data.len, MAX_DATAGRAM);
        @memcpy(s.dgram.data[0..s.dgram.len], data[0..s.dgram.len]);
        s.pending = true;
        return;
    }
    @import("socket.zig").deliverUdpLocked(dst_port, src_ip, src_port, data);
}

/// Send a raw IPv4 payload with the given protocol number. Used by TCP, which
/// builds its own segments, and by ping. Never waits: an unknown next hop gets
/// an ARP request and the packet is reported undeliverable for now.
pub fn sendRawLocked(dst_ip: Ipv4Addr, proto: u8, payload: []const u8) Error!void {
    if (payload.len + ETH_HEADER_LEN + 20 > 1600) return Error.TooLarge;
    const via = nextHop(dst_ip);
    const dst_mac = arpLookup(via) orelse {
        // Hold the packet until the answer arrives, so a connection's first
        // SYN is not lost to address resolution.
        holdPending(via, dst_ip, proto, payload);
        sendArpRequest(via) catch {};
        return Error.NoRoute;
    };

    var frame: [1600]u8 = undefined;
    const n = buildIpv4(&frame, dst_mac, dst_ip, proto, payload);
    try e1000.send(frame[0..n]);
}

/// Packets waiting for their next hop's hardware address. A few are enough:
/// they cover the first packets to a new host; later ones find the cache.
const Pending = struct {
    used: bool = false,
    via: Ipv4Addr = .{ 0, 0, 0, 0 },
    dst: Ipv4Addr = .{ 0, 0, 0, 0 },
    proto: u8 = 0,
    len: usize = 0,
    since_us: u64 = 0,
    payload: [1560]u8 = undefined,
};
var pending: [8]Pending = [_]Pending{.{}} ** 8;

fn holdPending(via: Ipv4Addr, dst: Ipv4Addr, proto: u8, payload: []const u8) void {
    const now = tsc.microsSinceBoot();
    var slot: ?*Pending = null;
    for (&pending) |*p| {
        // Unanswered for 3 s: the host is not there.
        if (p.used and now - p.since_us > 3_000_000) p.used = false;
        if (!p.used and slot == null) slot = p;
    }
    const p = slot orelse return; // full: the sender retransmits
    p.* = .{ .used = true, .via = via, .dst = dst, .proto = proto, .len = payload.len, .since_us = now };
    @memcpy(p.payload[0..payload.len], payload);
}

fn flushPending(ip: Ipv4Addr, mac: MacAddr) void {
    for (&pending) |*p| {
        if (!p.used or !std.mem.eql(u8, &p.via, &ip)) continue;
        p.used = false;
        var frame: [1600]u8 = undefined;
        const n = buildIpv4(&frame, mac, p.dst, p.proto, p.payload[0..p.len]);
        e1000.send(frame[0..n]) catch {};
    }
}

/// 127.0.0.0/8, never sent to the gateway: datagram sockets deliver there
/// locally (socket.zig); TCP refuses it as unreachable.
pub fn isLoopback(ip: Ipv4Addr) bool {
    return ip[0] == 127;
}

// ── Receive path ────────────────────────────────────────────────────────────

var rx_buf: [2048]u8 = undefined;

fn handleIpv4(frame: []const u8) void {
    if (frame.len < ETH_HEADER_LEN + 20) return;
    const ip = frame[ETH_HEADER_LEN..];

    const ihl: usize = @as(usize, ip[0] & 0x0F) * 4;
    if (ihl < 20 or ip.len < ihl) return;

    const total_len = be16(ip, 2);
    if (total_len < ihl or total_len > ip.len) return;

    var src_ip: Ipv4Addr = undefined;
    @memcpy(&src_ip, ip[12..16]);

    var dst_ip: Ipv4Addr = undefined;
    @memcpy(&dst_ip, ip[16..20]);
    // Accept our own address and broadcast. Broadcast matters during DHCP,
    // when we do not have an address yet and the server answers to everyone.
    if (!std.mem.eql(u8, &dst_ip, &local_ip) and
        !std.mem.eql(u8, &dst_ip, &BROADCAST_IP)) return;

    const payload = ip[ihl..total_len];
    switch (ip[9]) {
        PROTO_ICMP => handleIcmp(payload, src_ip),
        PROTO_UDP => handleUdp(payload, src_ip),
        PROTO_TCP => @import("tcp.zig").input(payload, src_ip),
        else => {},
    }
}

/// Drain the receive ring and dispatch whatever arrived.
pub fn poll() void {
    const state = acquire();
    defer release(state);
    pollLocked();
}

pub fn pollLocked() void {
    while (e1000.receive(&rx_buf)) |len| {
        if (len < ETH_HEADER_LEN) continue;
        const frame = rx_buf[0..len];
        switch (be16(frame, 12)) {
            ETHERTYPE_ARP => handleArp(frame),
            ETHERTYPE_IPV4 => handleIpv4(frame),
            else => {},
        }
    }
}

// ── Network thread ──────────────────────────────────────────────────────────
//
// The card is polled, not interrupt-driven (e1000.zig). This thread drains
// it and runs TCP's timers, so connections progress and sockets become
// readable while no program is inside a network call. It polls every
// millisecond while any connection is active and every 20 ms otherwise
// (ARP answers, stray datagrams), which bounds the idle cost. Waiters are
// woken by the changes it makes, not by polling themselves.

fn serviceThread(_: ?*anyopaque) void {
    while (true) {
        const active = blk: {
            const state = acquire();
            defer release(state);
            pollLocked();
            break :blk @import("tcp.zig").timersLocked() or @import("socket.zig").udpOpenLocked();
        };
        sched.sleepMs(if (active) 1 else 20);
    }
}

/// Start the network thread; after the scheduler is up and only if a card
/// was found.
pub fn startService() void {
    if (!isUp()) return;
    _ = sched.spawn("net", serviceThread, null, .normal) catch {
        console.warn("net: could not start the network thread", .{});
    };
}

pub fn init() !void {
    const found = try e1000.init();
    if (!found) {
        console.info("networking: no supported card", .{});
        return;
    }
    e1000.report();

    // Ask the network what our address should be rather than asserting one.
    const dhcp = @import("dhcp.zig");
    if (dhcp.configure(3000)) {
        console.print("[ ok ] dhcp: leased {d}.{d}.{d}.{d}\n", .{
            local_ip[0], local_ip[1], local_ip[2], local_ip[3],
        });
    } else {
        console.warn("dhcp: no lease, using the built-in address", .{});
    }
    console.print("[ ok ] net: {d}.{d}.{d}.{d}/24, gateway {d}.{d}.{d}.{d}\n", .{
        local_ip[0],   local_ip[1],   local_ip[2],   local_ip[3],
        gateway_ip[0], gateway_ip[1], gateway_ip[2], gateway_ip[3],
    });
}

pub fn isUp() bool {
    return e1000.isPresent();
}

pub fn gateway() Ipv4Addr {
    return gateway_ip;
}

pub fn setAddress(ip: Ipv4Addr, gw: Ipv4Addr, mask: Ipv4Addr) void {
    local_ip = ip;
    gateway_ip = gw;
    netmask = mask;
}

pub fn dnsServer() Ipv4Addr {
    return dns_ip;
}

pub var dns_ip: Ipv4Addr = .{ 10, 0, 2, 3 };
