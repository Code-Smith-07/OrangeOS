//! Program exit interrupts a thread's long network wait: the parent times the
//! whole run and expects it to end well before the ping's 5 s timeout.
const pulp = @import("pulp");

/// TEST-NET-1 (RFC 5737): never routed, so the ping waits its full timeout.
const UNREACHABLE = [4]u8{ 192, 0, 2, 1 };
var waiting: u32 = 0;

fn waiter(_: *anyopaque) void {
    @atomicStore(u32, &waiting, 1, .release);
    _ = pulp.ping(UNREACHABLE, 1, 5000);
}

export fn _start() callconv(.c) noreturn {
    var context: u8 = 0;
    _ = pulp.Thread.spawn(waiter, &context, 64 * 1024, 0) catch pulp.exit(1);
    while (@atomicLoad(u32, &waiting, .acquire) == 0) pulp.yield();
    pulp.sleepMs(100);
    pulp.exit(7);
}
