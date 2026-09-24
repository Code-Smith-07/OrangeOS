//! Exercise IPC reference lifetime and registry reuse across process exits.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    const port_name = "ipc.probe.port";
    const shm_name = "ipc.probe.shm";

    // A queued message must be reclaimed with its last port reference.
    const queued = pulp.portCreate(port_name) catch pulp.exit(1);
    _ = pulp.portSend(queued, 7, "abandoned") catch pulp.exit(2);
    pulp.handleClose(queued);
    const port = pulp.portCreate(port_name) catch pulp.exit(3);
    const peer = pulp.portConnect(port_name) catch pulp.exit(4);
    _ = pulp.portSend(peer, 9, "live") catch pulp.exit(5);
    var receive: [8]u8 = undefined;
    const got = pulp.portRecvMsg(port, &receive, false) catch pulp.exit(6);
    if (got.opcode != 9 or got.len != 4 or !@import("std").mem.eql(u8, receive[0..4], "live")) pulp.exit(7);
    pulp.handleClose(peer);
    pulp.handleClose(port);

    const shm = pulp.shmCreate(shm_name, 4096) catch pulp.exit(8);
    const shared = pulp.shmMap(shm, true) catch pulp.exit(9);
    shared[0] = 0xa5;
    pulp.handleClose(shm);
    if (shared[0] != 0xa5) pulp.exit(10);
    // A mapping keeps the name and frames alive until address-space teardown.
    const open = pulp.shmOpen(shm_name) catch pulp.exit(11);
    const again = pulp.shmMap(open, false) catch pulp.exit(12);
    if (again[0] != 0xa5) pulp.exit(13);
    pulp.handleClose(open);

    const pty = pulp.ptyCreate() catch pulp.exit(14);
    const child = pulp.spawnPty("/bin/reap-probe", pty) catch pulp.exit(16);
    pulp.handleClose(pty);
    if ((pulp.wait(child) catch pulp.exit(17)) != 0) pulp.exit(18);
    // Leave named objects and mapped frames for process-exit cleanup.
    _ = pulp.portCreate("ipc.probe.exit") catch pulp.exit(15);
    pulp.exit(0);
}
