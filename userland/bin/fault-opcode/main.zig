const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    if (pulp.is_arm) asm volatile ("udf #0") else asm volatile ("ud2");
    pulp.exit(2);
}
