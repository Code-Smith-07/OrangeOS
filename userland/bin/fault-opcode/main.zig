const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    asm volatile ("ud2");
    pulp.exit(2);
}
