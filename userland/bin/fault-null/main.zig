const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    _ = pulp.mapMemory(1024 * 1024, .read_write) catch pulp.exit(1);
    asm volatile ("movq $0, %%rax; movq (%%rax), %%rax" ::: "rax", "memory");
    pulp.exit(2);
}
