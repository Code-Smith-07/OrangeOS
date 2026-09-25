//! Program exit ends every thread, whatever it is doing: blocked on a futex,
//! a port, the console or a child, sleeping, or spinning in user mode.
const std = @import("std");
const pulp = @import("pulp");

var word: u32 = 0;
var port: i64 = 0;
var child: i64 = 0;
var started: u32 = 0;

fn announce() void {
    _ = @atomicRmw(u32, &started, .Add, 1, .release);
}

fn blocker(_: *anyopaque) void {
    announce();
    while (true) pulp.waitWord(&word, 0, 0) catch {};
}

fn sleeper(_: *anyopaque) void {
    announce();
    while (true) pulp.sleepMs(60_000);
}

fn spinner(_: *anyopaque) void {
    announce();
    while (true) asm volatile ("pause");
}

fn receiver(_: *anyopaque) void {
    announce();
    var buffer: [16]u8 = undefined;
    while (true) _ = pulp.portRecv(port, &buffer, true) catch {};
}

fn waiter(_: *anyopaque) void {
    announce();
    _ = pulp.wait(child) catch {};
    while (true) pulp.sleepMs(60_000);
}

fn reader(_: *anyopaque) void {
    announce();
    var byte: [1]u8 = undefined;
    while (true) _ = pulp.read(pulp.STDIN, &byte) catch {};
}

export fn _start() callconv(.c) noreturn {
    var name: [32]u8 = undefined;
    const port_name = std.fmt.bufPrint(&name, "thread-exit.{d}", .{pulp.getpid()}) catch pulp.exit(1);
    port = pulp.portCreate(port_name) catch pulp.exit(2);
    // Lives longer than this program's exit takes, so the waiter is blocked.
    child = pulp.spawn("/bin/orphan-slow") catch pulp.exit(3);
    var context: u8 = 0;
    const entries = [_]*const fn (*anyopaque) void{ blocker, sleeper, spinner, receiver, waiter, reader };
    for (entries) |entry| _ = pulp.Thread.spawn(entry, &context, 64 * 1024, 0) catch pulp.exit(4);
    while (@atomicLoad(u32, &started, .acquire) < entries.len) pulp.sleepMs(1);
    // Give each thread time to reach its blocking point.
    pulp.sleepMs(20);
    pulp.exit(42);
}
