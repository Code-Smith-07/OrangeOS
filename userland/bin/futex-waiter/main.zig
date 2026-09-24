//! Child half of the shared-frame wait/wake probe.
const pulp = @import("pulp");

export fn _start() callconv(.c) noreturn {
    const handle = pulp.shmOpen("runtime.wait") catch pulp.exit(1);
    const mapping = pulp.shmMap(handle, true) catch pulp.exit(2);
    const words: [*]u32 = @ptrCast(@alignCast(mapping));
    _ = @atomicRmw(u32, &words[1], .Add, 1, .seq_cst);
    pulp.waitWord(&words[0], 0, 5000) catch pulp.exit(3);
    _ = @atomicRmw(u32, &words[2], .Add, 1, .seq_cst);
    pulp.handleClose(handle);
    pulp.exit(0);
}
