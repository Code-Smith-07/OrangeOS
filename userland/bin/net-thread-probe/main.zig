//! Network calls from several threads of one program at once: concurrent
//! pings sharing the NIC and the echo-reply table, concurrent UDP socket
//! churn, and a long network wait that another thread's munmap shootdowns
//! must be able to reach.
const std = @import("std");
const pulp = @import("pulp");

/// TEST-NET-1 (RFC 5737): never routed, so a ping to it waits its full time.
const UNREACHABLE = [4]u8{ 192, 0, 2, 1 };
const PINGERS = 3;
const PINGS = 8;

var gateway: [4]u8 = undefined;
var failed: u32 = 0;
var replies: u32 = 0;
var waiting: u32 = 0;

fn fail(code: u32) void {
    _ = @cmpxchgStrong(u32, &failed, 0, code, .monotonic, .monotonic);
}

const Pinger = struct { base: u16 };

fn pinger(arg: *anyopaque) void {
    const p: *Pinger = @ptrCast(@alignCast(arg));
    for (0..PINGS) |i| {
        if (pulp.ping(gateway, p.base + @as(u16, @intCast(i)), 2000) != null)
            _ = @atomicRmw(u32, &replies, .Add, 1, .monotonic);
    }
}

fn udpChurn(_: *anyopaque) void {
    for (0..32) |_| {
        const sock = pulp.udpOpen(0) catch {
            fail(1);
            return;
        };
        // The discard port: nothing answers, the send itself is the test.
        _ = pulp.udpSend(sock, gateway, 9, "orange") catch fail(2);
        pulp.udpClose(sock);
    }
}

fn longWait(_: *anyopaque) void {
    @atomicStore(u32, &waiting, 1, .release);
    if (pulp.ping(UNREACHABLE, 1, 3000) != null) fail(3);
    @atomicStore(u32, &waiting, 2, .release);
}

export fn _start() callconv(.c) noreturn {
    const info = pulp.netInfo() catch pulp.exit(10);
    if (info.up == 0) pulp.exit(11);
    gateway = pulp.unpackIp(info.gateway);

    var context: u8 = 0;
    var pingers: [PINGERS]Pinger = undefined;
    var threads: [PINGERS + 2]pulp.Thread = undefined;
    for (&pingers, 0..) |*p, i| {
        p.* = .{ .base = @intCast(100 * (i + 1)) };
        threads[i] = pulp.Thread.spawn(pinger, p, 64 * 1024, 0) catch pulp.exit(12);
    }
    threads[PINGERS] = pulp.Thread.spawn(udpChurn, &context, 64 * 1024, 0) catch pulp.exit(13);
    threads[PINGERS + 1] = pulp.Thread.spawn(udpChurn, &context, 64 * 1024, 0) catch pulp.exit(14);
    for (threads) |thread| thread.join();
    const answered = @atomicLoad(u32, &replies, .acquire);
    if (answered != PINGERS * PINGS) {
        pulp.print("net-thread-probe: FAIL {d}/{d} concurrent pings answered\n", .{ answered, PINGERS * PINGS });
        pulp.exit(15);
    }

    // A thread waits three seconds in the kernel for a reply that never
    // comes, while this one unmaps memory: every unmap must be able to shoot
    // down that thread's CPU instead of waiting on a CPU spinning masked.
    const waiter = pulp.Thread.spawn(longWait, &context, 64 * 1024, 0) catch pulp.exit(16);
    while (@atomicLoad(u32, &waiting, .acquire) == 0) pulp.yield();
    pulp.sleepMs(50);
    var unmaps: usize = 0;
    while (@atomicLoad(u32, &waiting, .acquire) != 2) {
        const memory = pulp.mapMemory(4096, .read_write) catch pulp.exit(17);
        memory[0] = 1;
        pulp.unmapMemory(memory) catch pulp.exit(18);
        unmaps += 1;
    }
    waiter.join();
    if (@atomicLoad(u32, &failed, .acquire) != 0) {
        pulp.print("net-thread-probe: FAIL check {d}\n", .{failed});
        pulp.exit(19);
    }
    pulp.print("net-thread-probe: PASS {d}/{d} concurrent pings, UDP churn, {d} unmaps during a 3 s network wait\n", .{ answered, PINGERS * PINGS, unmaps });
    pulp.exit(0);
}
