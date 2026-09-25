//! Two threads fetch a known payload over TCP at the same time, from a
//! loopback fixture that tools/runtime_smoke.py serves on the host (QEMU's
//! user network shows the host as 10.0.2.2). Every byte is checked. Without
//! the fixture the connection is refused and the probe reports SKIP.
const std = @import("std");
const pulp = @import("pulp");

const HOST = [4]u8{ 10, 0, 2, 2 };
const PORT: u16 = 38457;
const PAYLOAD_LEN = 6000;
const THREADS = 2;

var failed: u32 = 0;
var refused: u32 = 0;
var received: [THREADS]usize = .{ 0, 0 };

fn fail(code: u32) void {
    _ = @cmpxchgStrong(u32, &failed, 0, code, .monotonic, .monotonic);
}

fn expected(token: u8, index: usize) u8 {
    return @truncate(index *% 31 +% token);
}

const Fetch = struct { index: usize, token: u8 };

fn fetch(arg: *anyopaque) void {
    const f: *Fetch = @ptrCast(@alignCast(arg));
    const sock = pulp.tcpConnect(HOST, PORT, 5000) catch |err| {
        if (err == error.ConnectionRefused) {
            _ = @atomicRmw(u32, &refused, .Add, 1, .monotonic);
        } else fail(1);
        return;
    };
    defer pulp.tcpClose(sock);
    var request: [32]u8 = undefined;
    const line = std.fmt.bufPrint(&request, "orange-tcp {d}\n", .{f.token}) catch unreachable;
    _ = pulp.tcpSend(sock, line) catch {
        fail(2);
        return;
    };
    var buffer: [1024]u8 = undefined;
    var total: usize = 0;
    while (total < PAYLOAD_LEN) {
        const n = pulp.tcpRecv(sock, &buffer, 5000) catch {
            fail(3);
            return;
        };
        if (n == 0) break;
        for (buffer[0..n], 0..) |byte, i| {
            if (byte != expected(f.token, total + i)) fail(4);
        }
        total += n;
    }
    received[f.index] = total;
    if (total != PAYLOAD_LEN) fail(5);
}

export fn _start() callconv(.c) noreturn {
    var fetches: [THREADS]Fetch = undefined;
    var threads: [THREADS]pulp.Thread = undefined;
    const base: u8 = @truncate(@as(u64, @intCast(pulp.getpid())));
    for (&fetches, 0..) |*f, i| {
        f.* = .{ .index = i, .token = base +% @as(u8, @intCast(i)) };
        threads[i] = pulp.Thread.spawn(fetch, f, 64 * 1024, 0) catch pulp.exit(10);
    }
    for (threads) |thread| thread.join();
    if (@atomicLoad(u32, &refused, .acquire) == THREADS) {
        pulp.puts("tcp-probe: SKIP no host fixture on 10.0.2.2:38457\n");
        pulp.exit(0);
    }
    if (@atomicLoad(u32, &failed, .acquire) != 0 or @atomicLoad(u32, &refused, .acquire) != 0) {
        pulp.print("tcp-probe: FAIL check {d}, refused {d}, bytes {d}/{d}\n", .{ failed, refused, received[0], received[1] });
        pulp.exit(11);
    }
    pulp.print("tcp-probe: PASS {d} threads each fetched {d} verified bytes concurrently\n", .{ THREADS, PAYLOAD_LEN });
    pulp.exit(0);
}
