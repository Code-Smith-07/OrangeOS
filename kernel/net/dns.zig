//! A minimal DNS resolver.
//!
//! One query, one answer, A records only. Enough to turn a hostname into an
//! address, which is the point at which a network stack becomes usable rather
//! than merely correct.

const std = @import("std");
const net = @import("net.zig");
const tsc = @import("../time/tsc.zig");

const DNS_PORT: u16 = 53;
const TYPE_A: u16 = 1;
const CLASS_IN: u16 = 1;

var query_id: u16 = 0x4F53;

inline fn putBe16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v >> 8);
    buf[off + 1] = @truncate(v);
}

inline fn be16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | buf[off + 1];
}

/// Names go on the wire as length-prefixed labels: "a.com" becomes
/// [1]'a'[3]'c''o''m'[0]. There are no dots in the encoding.
fn encodeName(buf: []u8, name: []const u8) ?usize {
    var out: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    while (i <= name.len) : (i += 1) {
        if (i < name.len and name[i] != '.') continue;

        const label_len = i - start;
        if (label_len == 0 or label_len > 63) return null;
        if (out + 1 + label_len + 1 > buf.len) return null;

        buf[out] = @intCast(label_len);
        @memcpy(buf[out + 1 .. out + 1 + label_len], name[start..i]);
        out += 1 + label_len;
        start = i + 1;
    }

    buf[out] = 0;
    return out + 1;
}

/// Skip over a name in a response, which may be a pointer rather than labels.
fn skipName(buf: []const u8, start: usize) ?usize {
    var i = start;
    while (i < buf.len) {
        const len = buf[i];
        // Two high bits set marks a compression pointer, which is always the
        // last thing in a name and occupies two bytes.
        if (len & 0xC0 == 0xC0) return i + 2;
        if (len == 0) return i + 1;
        i += 1 + @as(usize, len);
    }
    return null;
}

/// Resolve `name` to an IPv4 address.
pub fn resolve(name: []const u8, timeout_ms: u64) ?net.Ipv4Addr {
    const sock = net.socketOpen(0) orelse return null;
    defer net.socketClose(sock);

    var query: [512]u8 = undefined;
    query_id +%= 1;

    putBe16(&query, 0, query_id);
    putBe16(&query, 2, 0x0100); // standard query, recursion desired
    putBe16(&query, 4, 1); // one question
    putBe16(&query, 6, 0);
    putBe16(&query, 8, 0);
    putBe16(&query, 10, 0);

    const name_len = encodeName(query[12..], name) orelse return null;
    var n = 12 + name_len;
    putBe16(&query, n, TYPE_A);
    putBe16(&query, n + 2, CLASS_IN);
    n += 4;

    net.sendTo(sock, net.dnsServer(), DNS_PORT, query[0..n]) catch return null;

    const deadline = tsc.microsSinceBoot() + timeout_ms * 1000;
    while (tsc.microsSinceBoot() < deadline) {
        net.poll();

        if (net.recvFrom(sock)) |d| {
            const resp = d.data[0..d.len];
            if (resp.len < 12) continue;
            if (be16(resp, 0) != query_id) continue;

            const questions = be16(resp, 4);
            const answers = be16(resp, 6);
            if (answers == 0) return null;

            // Step over the echoed question section.
            var off: usize = 12;
            var q: usize = 0;
            while (q < questions) : (q += 1) {
                off = skipName(resp, off) orelse return null;
                off += 4; // type and class
            }

            var a: usize = 0;
            while (a < answers) : (a += 1) {
                off = skipName(resp, off) orelse return null;
                if (off + 10 > resp.len) return null;

                const rtype = be16(resp, off);
                const rdlen = be16(resp, off + 8);
                off += 10;
                if (off + rdlen > resp.len) return null;

                if (rtype == TYPE_A and rdlen == 4) {
                    return .{ resp[off], resp[off + 1], resp[off + 2], resp[off + 3] };
                }
                off += rdlen;
            }
            return null;
        }
        asm volatile ("pause");
    }
    return null;
}
