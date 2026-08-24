//! DHCP client.
//!
//! Four messages: DISCOVER, OFFER, REQUEST, ACK. The first two are broadcast
//! because the client has no address yet, which is also why the IPv4 receive
//! path has to accept packets addressed to 255.255.255.255 — a machine that
//! only accepts traffic for its own address can never obtain one.
//!
//! The wire format is BOOTP with a magic cookie and a list of options tacked
//! on the end. Options are type/length/value triples, terminated by 0xFF.

const std = @import("std");
const net = @import("net.zig");
const e1000 = @import("../drivers/net/e1000.zig");
const console = @import("../console.zig");
const tsc = @import("../time/tsc.zig");

const CLIENT_PORT: u16 = 68;
const SERVER_PORT: u16 = 67;

const OP_REQUEST: u8 = 1;
const OP_REPLY: u8 = 2;

const MAGIC = [4]u8{ 0x63, 0x82, 0x53, 0x63 };

const OPT_SUBNET: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS: u8 = 6;
const OPT_REQUESTED_IP: u8 = 50;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_PARAM_LIST: u8 = 55;
const OPT_END: u8 = 0xFF;

const DHCP_DISCOVER: u8 = 1;
const DHCP_OFFER: u8 = 2;
const DHCP_REQUEST: u8 = 3;
const DHCP_ACK: u8 = 5;

/// BOOTP fixed header is 236 bytes; options follow the magic cookie.
const BOOTP_LEN: usize = 236;
const PACKET_LEN: usize = 300;

var xid: u32 = 0x4F52_4E47; // "ORNG"

fn buildBase(buf: []u8, msg_type: u8) usize {
    @memset(buf[0..PACKET_LEN], 0);

    buf[0] = OP_REQUEST;
    buf[1] = 1; // Ethernet
    buf[2] = 6; // MAC length
    buf[3] = 0; // hops

    buf[4] = @truncate(xid >> 24);
    buf[5] = @truncate(xid >> 16);
    buf[6] = @truncate(xid >> 8);
    buf[7] = @truncate(xid);

    // Broadcast flag: we cannot receive unicast without an address.
    buf[10] = 0x80;

    const mac = e1000.macAddress();
    @memcpy(buf[28..34], &mac);

    @memcpy(buf[BOOTP_LEN .. BOOTP_LEN + 4], &MAGIC);

    var i = BOOTP_LEN + 4;
    buf[i] = OPT_MSG_TYPE;
    buf[i + 1] = 1;
    buf[i + 2] = msg_type;
    i += 3;

    return i;
}

fn finish(buf: []u8, i: usize) usize {
    buf[i] = OPT_END;
    return @max(i + 1, PACKET_LEN);
}

fn findOption(buf: []const u8, want: u8) ?[]const u8 {
    if (buf.len < BOOTP_LEN + 4) return null;
    if (!std.mem.eql(u8, buf[BOOTP_LEN .. BOOTP_LEN + 4], &MAGIC)) return null;

    var i = BOOTP_LEN + 4;
    while (i + 1 < buf.len) {
        const code = buf[i];
        if (code == OPT_END) return null;
        if (code == 0) {
            i += 1; // pad
            continue;
        }
        const len = buf[i + 1];
        if (i + 2 + len > buf.len) return null;
        if (code == want) return buf[i + 2 .. i + 2 + len];
        i += 2 + @as(usize, len);
    }
    return null;
}

fn readIp(opt: []const u8) ?net.Ipv4Addr {
    if (opt.len < 4) return null;
    return .{ opt[0], opt[1], opt[2], opt[3] };
}

/// Run the exchange. Returns true if an address was obtained.
pub fn configure(timeout_ms: u64) bool {
    const sock = net.socketOpen(CLIENT_PORT) orelse return false;
    defer net.socketClose(sock);

    var packet: [PACKET_LEN]u8 = undefined;

    // ── DISCOVER ────────────────────────────────────────────────────────────
    var n = buildBase(&packet, DHCP_DISCOVER);
    packet[n] = OPT_PARAM_LIST;
    packet[n + 1] = 3;
    packet[n + 2] = OPT_SUBNET;
    packet[n + 3] = OPT_ROUTER;
    packet[n + 4] = OPT_DNS;
    n = finish(&packet, n + 5);

    net.sendTo(sock, net.BROADCAST_IP, SERVER_PORT, packet[0..n]) catch return false;

    const offer = waitFor(sock, DHCP_OFFER, timeout_ms) orelse return false;

    var offered: net.Ipv4Addr = .{ offer.data[16], offer.data[17], offer.data[18], offer.data[19] };
    const server_id = if (findOption(offer.data[0..offer.len], OPT_SERVER_ID)) |o|
        readIp(o) orelse return false
    else
        return false;

    // ── REQUEST ─────────────────────────────────────────────────────────────
    n = buildBase(&packet, DHCP_REQUEST);
    packet[n] = OPT_REQUESTED_IP;
    packet[n + 1] = 4;
    @memcpy(packet[n + 2 .. n + 6], &offered);
    n += 6;
    packet[n] = OPT_SERVER_ID;
    packet[n + 1] = 4;
    @memcpy(packet[n + 2 .. n + 6], &server_id);
    n = finish(&packet, n + 6);

    net.sendTo(sock, net.BROADCAST_IP, SERVER_PORT, packet[0..n]) catch return false;

    const ack = waitFor(sock, DHCP_ACK, timeout_ms) orelse return false;

    var mask: net.Ipv4Addr = .{ 255, 255, 255, 0 };
    var router: net.Ipv4Addr = server_id;

    if (findOption(ack.data[0..ack.len], OPT_SUBNET)) |o| {
        if (readIp(o)) |v| mask = v;
    }
    if (findOption(ack.data[0..ack.len], OPT_ROUTER)) |o| {
        if (readIp(o)) |v| router = v;
    }
    if (findOption(ack.data[0..ack.len], OPT_DNS)) |o| {
        if (readIp(o)) |v| net.dns_ip = v;
    }

    offered = .{ ack.data[16], ack.data[17], ack.data[18], ack.data[19] };
    net.setAddress(offered, router, mask);
    return true;
}

fn waitFor(sock: usize, msg_type: u8, timeout_ms: u64) ?*const net.Datagram {
    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    while (tsc.microsSinceBoot() < deadline) {
        net.poll();
        if (net.recvFrom(sock)) |d| {
            if (d.len < BOOTP_LEN + 4) continue;
            if (d.data[0] != OP_REPLY) continue;
            if (findOption(d.data[0..d.len], OPT_MSG_TYPE)) |o| {
                if (o.len >= 1 and o[0] == msg_type) return d;
            }
        }
        asm volatile ("pause");
    }
    return null;
}
