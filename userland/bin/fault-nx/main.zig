const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    const memory = pulp.mapMemory(4096, .read_write) catch pulp.exit(1);
    memory[0] = 0xc3; // RET: harmless if NX accidentally allows execution.
    const function: *const fn () callconv(.c) void = @ptrCast(memory.ptr);
    function();
    pulp.exit(2);
}
