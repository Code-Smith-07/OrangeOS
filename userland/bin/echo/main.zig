//! echo — print a fixed greeting.
//!
//! Argument passing to spawned programs is not implemented yet (Phase 6b adds
//! argv), so this exists mainly to prove that the shell can spawn a separate
//! binary from disk, run it in its own address space, and collect its exit
//! code.

const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    pulp.print("hello from a separate process, pid {d}\n", .{pulp.getpid()});
    pulp.exit(0);
}
