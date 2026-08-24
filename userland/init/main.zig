//! init — PID 1.
//!
//! Phase 6a version: verify the system came up sane, then start the shell and
//! keep restarting it if it exits. Service supervision and dependency ordering
//! arrive with Seed.

const pulp = @import("pulp");

const SHELL = "/bin/juice";

fn banner() void {
    pulp.puts("\n");
    pulp.puts("  \x1b[38;5;208m+--------------------------------------------+\x1b[0m\n");
    pulp.puts("  \x1b[38;5;208m|\x1b[0m  Orange OS - init (pid 1)                  \x1b[38;5;208m|\x1b[0m\n");
    pulp.puts("  \x1b[38;5;208m+--------------------------------------------+\x1b[0m\n");
}

/// Confirm the kernel handed us a working system before starting anything.
fn selfCheck() void {
    pulp.print("  pid ................ {d}\n", .{pulp.getpid()});
    pulp.print("  uptime ............. {d} ms\n", .{pulp.uptimeMs()});

    // The filesystem must be readable.
    if (pulp.open("/etc/motd")) |fd| {
        var buf: [128]u8 = undefined;
        const n = pulp.read(@intCast(fd), &buf) catch 0;
        pulp.close(fd);
        pulp.print("  /etc/motd .......... {d} bytes\n", .{n});
    } else |_| {
        pulp.puts("  /etc/motd .......... MISSING\n");
    }

    // The kernel must still refuse a kernel-half pointer.
    const bad = pulp.syscall3(pulp.NR.write, 1, 0xFFFF_FFFF_8000_0000, 32);
    pulp.print("  memory protection .. {s}\n", .{
        if (bad < 0) "enforced" else "BROKEN",
    });
    pulp.puts("\n");
}

export fn _start() callconv(.c) noreturn {
    banner();
    selfCheck();

    // Supervise the shell: if it exits, start it again. PID 1 exiting would
    // leave the system with nothing to run.
    var restarts: u32 = 0;
    while (true) {
        const pid = pulp.spawn(SHELL) catch {
            pulp.print("init: cannot start {s}\n", .{SHELL});
            pulp.exit(1);
        };

        const code = pulp.wait(pid) catch 0;
        restarts += 1;
        pulp.print("\ninit: {s} exited with {d}, restarting ({d})\n", .{ SHELL, code, restarts });
    }
}
