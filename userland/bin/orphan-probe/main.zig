//! Leave both an already-exited child and a still-running child to the reaper.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    _ = pulp.spawn("/bin/reap-probe") catch |err| {
        pulp.print("orphan-probe: quick spawn {s}\n", .{@errorName(err)});
        pulp.exit(1);
    };
    pulp.sleepMs(40);
    _ = pulp.spawn("/bin/orphan-slow") catch |err| {
        pulp.print("orphan-probe: slow spawn {s}\n", .{@errorName(err)});
        pulp.exit(2);
    };
    // Neither child is waited. The short delay gives the quick child time to
    // become a zombie while the other remains live when this parent exits.
    pulp.exit(0);
}
