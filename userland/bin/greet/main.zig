//! greet — IPC client.
//!
//! Connects to greetd by name, sends a request, and prints the reply. Proves
//! two separate processes in separate address spaces exchange messages through
//! the kernel, and that shared memory is genuinely shared.

const pulp = @import("pulp");

const OP_HELLO: u32 = 1;

export fn _start() callconv(.c) noreturn {
    const port = pulp.portConnect("greet") catch {
        pulp.puts("greet: greetd is not running\n");
        pulp.exit(1);
    };
    const reply = pulp.portConnect("greet.reply") catch {
        pulp.puts("greet: no reply port\n");
        pulp.exit(1);
    };

    pulp.print("  connected: port handle {d}, reply handle {d}\n", .{ port, reply });

    _ = pulp.portSend(port, OP_HELLO, "juice user") catch {
        pulp.puts("greet: send failed\n");
        pulp.exit(1);
    };

    var buf: [256]u8 = undefined;
    const n = pulp.portRecv(reply, &buf, true) catch {
        pulp.puts("greet: no reply\n");
        pulp.exit(1);
    };

    pulp.print("  greetd says: {s}\n", .{buf[0..n]});

    // Shared memory: write through one mapping, read back through a second.
    // If the kernel were copying instead of sharing frames, the second mapping
    // would not see the write.
    const shm = pulp.shmCreate(4096) catch {
        pulp.puts("greet: shm_create failed\n");
        pulp.exit(1);
    };
    const a = pulp.shmMap(shm, true) catch pulp.exit(1);
    const b = pulp.shmMap(shm, true) catch pulp.exit(1);

    const marker = "shared-memory-works";
    @memcpy(a[0..marker.len], marker);

    const same = blk: {
        var i: usize = 0;
        while (i < marker.len) : (i += 1) {
            if (b[i] != marker[i]) break :blk false;
        }
        break :blk true;
    };

    pulp.print("  shm: two mappings of one object agree: {s}\n", .{
        if (same) "yes" else "NO",
    });
    pulp.print("  shm: mapped at 0x{x} and 0x{x}\n", .{ @intFromPtr(a), @intFromPtr(b) });

    pulp.handleClose(port);
    pulp.handleClose(reply);
    pulp.exit(0);
}
