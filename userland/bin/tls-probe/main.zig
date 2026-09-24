//! Prove FS-relative user TLS survives preemption, blocking and CPU migration.
const pulp = @import("pulp");

comptime {
    asm (
        \\.section .text
        \\.global tlsProbeCpuId
        \\tlsProbeCpuId:
        \\    pushq %rbx
        \\    movl $1, %eax
        \\    cpuid
        \\    shrl $24, %ebx
        \\    movl %ebx, %eax
        \\    popq %rbx
        \\    retq
    );
}

extern fn tlsProbeCpuId() callconv(.c) u32;

fn tlsValue() u64 {
    return asm volatile ("movq %%fs:0, %[value]"
        : [value] "=r" (-> u64),
    );
}

export fn _start() callconv(.c) noreturn {
    if (pulp.getTlsBase() != 0) pulp.exit(1);
    const page = pulp.mapMemory(4096, .read_write) catch pulp.exit(2);
    const cell: *u64 = @ptrCast(page.ptr);
    const expected: u64 = 0xA11C_E5EE_D15C_0000 ^ @as(u64, @intCast(pulp.getpid()));
    cell.* = expected;
    pulp.setTlsBase(@intFromPtr(cell)) catch pulp.exit(3);
    if (pulp.getTlsBase() != @intFromPtr(cell) or tlsValue() != expected) pulp.exit(4);
    if (pulp.syscall1(pulp.NR.tls_set_base, 0x0000_8000_0000_0000) != -22) pulp.exit(5);
    if (pulp.syscall1(pulp.NR.tls_set_base, 0xffff_8000_0000_0000) != -22) pulp.exit(6);
    if (pulp.getTlsBase() != @intFromPtr(cell)) pulp.exit(7);

    var cpus: u64 = 0;
    for (0..256) |i| {
        const cpu = tlsProbeCpuId() & 63;
        cpus |= @as(u64, 1) << @intCast(cpu);
        if (tlsValue() != expected or pulp.getTlsBase() != @intFromPtr(cell)) pulp.exit(8);
        if (i % 8 == 0) pulp.sleepMs(1) else pulp.yield();
    }
    pulp.setTlsBase(0) catch pulp.exit(9);
    if (pulp.getTlsBase() != 0) pulp.exit(10);
    pulp.unmapMemory(page) catch pulp.exit(11);
    pulp.print("tls-probe: PASS pid={d} cpus={x}\n", .{ pulp.getpid(), cpus });
    pulp.exit(0);
}
