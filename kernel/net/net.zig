//! Network stack — Ethernet, ARP, IPv4, ICMP.
//!
//! Everything on the wire is big-endian and nothing is aligned, so all header
//! access goes through explicit byte reads rather than struct overlays. A
//! packed struct would be shorter and would break the first time a header
//! landed at an odd offset.

const std = @import("std");
const e1000 = @import("../drivers/net/e1000.zig");
const console = @import("../console.zig");
const tsc = @import("../time/tsc.zig");

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

/// Resolve an address, sending requests until an answer arrives.
pub fn resolve(ip: Ipv4Addr, timeout_ms: u64) ?MacAddr {
    if (arpLookup(ip)) |m| return m;

    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        sendArpRequest(ip) catch return null;

        const deadline = tsc.microsSinceBoot() + (timeout_ms * 1000) / 4;
        while (tsc.microsSinceBoot() < deadline) {
            poll();
            if (arpLookup(ip)) |m| return m;
            asm volatile ("pause");
        }
    }
    return null;
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

var last_reply_seq: u16 = 0;
var got_reply: bool = false;
var reply_from: Ipv4Addr = .{ 0, 0, 0, 0 };

fn handleIcmp(ip_payload: []const u8, src_ip: Ipv4Addr) void {
    if (ip_payload.len < 8) return;

    switch (ip_payload[0]) {
        ICMP_ECHO_REPLY => {
            last_reply_seq = be16(ip_payload, 6);
            reply_from = src_ip;
            got_reply = true;
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
/// microseconds, or null on timeout.
pub fn ping(dst_ip: Ipv4Addr, seq: u16, timeout_ms: u64) ?u64 {
    const dst_mac = resolve(dst_ip, 1000) orelse return null;

    var payload: [40]u8 = undefined;
    @memset(&payload, 0);
    payload[0] = ICMP_ECHO_REQUEST;
    payload[1] = 0;
    putBe16(&payload, 2, 0); // checksum
    putBe16(&payload, 4, 0x4F53); // identifier: "OS"
    putBe16(&payload, 6, seq);
    for (payload[8..], 0..) |*b, i| b.* = @truncate(i);

    const sum = checksum(&payload);
    putBe16(&payload, 2, sum);

    var frame: [1518]u8 = undefined;
    const total = buildIpv4(&frame, dst_mac, dst_ip, PROTO_ICMP, &payload);

    got_reply = false;
    const start = tsc.microsSinceBoot();
    e1000.send(frame[0..total]) catch return null;

    const deadline = start + timeout_ms * 1000;
    while (tsc.microsSinceBoot() < deadline) {
        poll();
        if (got_reply and last_reply_seq == seq) {
            return tsc.microsSinceBoot() - start;
        }
        asm volatile ("pause");
    }
    return null;
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
    var chosen = port;
    if (chosen == 0) {
        chosen = ephemeral_next;
        ephemeral_next +%= 1;
        if (ephemeral_next < 49152) ephemeral_next = 49152;
    }

    for (&sockets, 0..) |*s, i| {
        if (s.used) continue;
        s.* = .{ .used = true, .port = chosen };
        return i;
    }
    return null;
}

pub fn socketClose(index: usize) void {
    if (index >= MAX_SOCKETS) return;
    sockets[index].used = false;
}

pub fn socketPort(index: usize) u16 {
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
    if (index >= MAX_SOCKETS or !sockets[index].used) return Error.NoRoute;
    if (payload.len > MAX_DATAGRAM) return Error.TooLarge;

    // Anything off-net goes via the gateway; anything local goes direct.
    const via = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const dst_mac = if (std.mem.eql(u8, &dst_ip, &BROADCAST_IP))
        BROADCAST
    else
        resolve(via, 1000) orelse return Error.NoRoute;

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

/// Take a pending datagram, if one has arrived.
pub fn recvFrom(index: usize) ?*const Datagram {
    if (index >= MAX_SOCKETS or !sockets[index].used) return null;
    if (!sockets[index].pending) return null;
    sockets[index].pending = false;
    return &sockets[index].dgram;
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
}

/// Send a raw IPv4 payload with the given protocol number. Used by TCP, which
/// builds its own segments.
pub fn sendRaw(dst_ip: Ipv4Addr, proto: u8, payload: []const u8) Error!void {
    const via = if (sameSubnet(dst_ip)) dst_ip else gateway_ip;
    const dst_mac = resolve(via, 1000) orelse return Error.NoRoute;

    var frame: [1600]u8 = undefined;
    if (payload.len + ETH_HEADER_LEN + 20 > frame.len) return Error.TooLarge;

    const n = buildIpv4(&frame, dst_mac, dst_ip, proto, payload);
    try e1000.send(frame[0..n]);
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
