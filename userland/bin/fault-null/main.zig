const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    _ = pulp.mapMemory(1024 * 1024, .read_write) catch pulp.exit(1);
    if (pulp.is_arm) {
        asm volatile ("mov x9, #0; ldr x9, [x9]" ::: "x9", "memory");
    } else {
        asm volatile ("movq $0, %%rax; movq (%%rax), %%rax" ::: "rax", "memory");
    }
    pulp.exit(2);
}
