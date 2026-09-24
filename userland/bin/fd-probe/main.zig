//! Verify descriptor isolation, per-process capacity and slot reuse.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    var one: [1]u8 = undefined;
    if (pulp.syscall3(pulp.NR.read, 3, @intFromPtr(&one), 1) != -9) pulp.exit(1);
    if (pulp.syscall3(pulp.NR.read, 0x8000_0000_0000_0000, @intFromPtr(&one), 1) != -9) pulp.exit(9);
    if (pulp.syscall1(pulp.NR.close, 0x8000_0000_0000_0000) != -9) pulp.exit(10);

    var files: [32]i64 = undefined;
    for (&files, 0..) |*fd, i| {
        fd.* = pulp.open("/etc/motd") catch pulp.exit(2);
        if (fd.* != @as(i64, @intCast(i + 3))) pulp.exit(3);
    }
    if (pulp.open("/etc/motd") != error.TooManyOpen) pulp.exit(4);
    if ((pulp.read(@intCast(files[0]), &one) catch pulp.exit(5)) != 1 or one[0] != 'W') pulp.exit(6);

    pulp.close(files[10]);
    const reused = pulp.open("/etc/motd") catch pulp.exit(7);
    if (reused != files[10]) pulp.exit(8);
    // Intentionally leave all descriptors open: process exit must close them.
    pulp.exit(0);
}
