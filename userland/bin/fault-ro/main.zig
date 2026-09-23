const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    const memory = pulp.mapMemory(4096, .read_write) catch pulp.exit(1);
    pulp.protectMemory(memory, .read) catch pulp.exit(1);
    @as(*volatile u8, @ptrCast(memory.ptr)).* = 42;
    pulp.exit(2);
}
