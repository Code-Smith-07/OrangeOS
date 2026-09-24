//! Exercise UDP ownership and exit cleanup without using an external server.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    var byte: [1]u8 = undefined;
    if (pulp.syscall1(pulp.NR.udp_close, 0) != -9) pulp.exit(1);
    if (pulp.syscall3(pulp.NR.udp_recv, 0, @intFromPtr(&byte), 1) != -9) pulp.exit(2);
    if (pulp.syscall1(pulp.NR.tcp_close, 0) != -9) pulp.exit(3);
    if (pulp.syscall4(pulp.NR.udp_send, 0, 0, 0, 0) != -9) pulp.exit(9);
    if (pulp.syscall3(pulp.NR.tcp_send, 0, @intFromPtr(&byte), 1) != -9) pulp.exit(10);
    if (pulp.syscall4(pulp.NR.tcp_recv, 0, @intFromPtr(&byte), 1, 0) != -9) pulp.exit(11);

    var sockets: [7]i64 = undefined;
    for (&sockets, 0..) |*sock, i| {
        sock.* = pulp.udpOpen(0) catch pulp.exit(4);
        if (sock.* != @as(i64, @intCast(i + 1))) pulp.exit(5);
    }
    if (pulp.udpOpen(0) != error.TooManyOpen) pulp.exit(6);
    pulp.udpClose(sockets[3]);
    const reused = pulp.udpOpen(0) catch pulp.exit(7);
    if (reused != sockets[3]) pulp.exit(8);
    // Leave all seven sockets for process-exit reclamation.
    pulp.exit(0);
}
