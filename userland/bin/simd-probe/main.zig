//! Native process-state isolation probe, not a browser executable.
const pulp = @import("pulp");
export var simd_initial: [512]u8 align(16) = [_]u8{0} ** 512;
comptime {
    asm (
        \\.section .text
        \\.global _start
        \\_start:
        \\    fxsave64 simd_initial(%rip)
        \\    subq $8, %rsp
        \\    call simdProbeMain
        \\    ud2
        \\.global simdStress
        \\simdStress:
        \\    pushq %rbx
        \\    pushq %r12
        \\    pushq %r13
        \\    pushq %r14
        \\    pushq %r15
        \\    subq $528, %rsp
        \\    fxsave64 (%rsp)
        \\    movq %rdi, %r12
        \\    movq %rsi, %r13
        \\    movq %rdx, 512(%rsp)
        \\    movq %rcx, %r15
        \\    fxrstor64 (%r12)
        \\1:
        \\    movq $4, %rax
        \\    syscall
        \\    movq $7, %rax
        \\    syscall
        \\    movq $120000, %r14
        \\2:
        \\    decq %r14
        \\    jnz 2b
        \\    movq $61, %rax
        \\    movq $1, %rdi
        \\    syscall
        \\    movl $1, %eax
        \\    cpuid
        \\    shrl $24, %ebx
        \\    andl $63, %ebx
        \\    btsq %rbx, (%r15)
        \\    fxsave64 (%r13)
        \\    movq %r12, %rsi
        \\    movq %r13, %rdi
        \\    movq $5, %rcx
        \\    repe cmpsb
        \\    jne 5f
        \\    leaq 6(%r12), %rsi
        \\    leaq 6(%r13), %rdi
        \\    movq $22, %rcx
        \\    repe cmpsb
        \\    jne 5f
        \\    movq $32, %r14
        \\3:
        \\    leaq (%r12,%r14), %rsi
        \\    leaq (%r13,%r14), %rdi
        \\    movq $10, %rcx
        \\    repe cmpsb
        \\    jne 5f
        \\    addq $16, %r14
        \\    cmpq $160, %r14
        \\    jne 3b
        \\    leaq 160(%r12), %rsi
        \\    leaq 160(%r13), %rdi
        \\    movq $256, %rcx
        \\    repe cmpsb
        \\    jne 5f
        \\    decq 512(%rsp)
        \\    jnz 1b
        \\    xorl %eax, %eax
        \\    jmp 6f
        \\5:
        \\    movl $1, %eax
        \\6:
        \\    fxrstor64 (%rsp)
        \\    addq $528, %rsp
        \\    popq %r15
        \\    popq %r14
        \\    popq %r13
        \\    popq %r12
        \\    popq %rbx
        \\    retq
        \\.global simdArithmetic
        \\simdArithmetic:
        \\    movq %rdi, %xmm0
        \\    addsd %xmm0, %xmm0
        \\    movq %xmm0, %rax
        \\    retq
    );
}
extern fn simdStress(expected: *const [512]u8, result: *[512]u8, rounds: u64, cpu_mask: *u64) callconv(.c) u64;
extern fn simdArithmetic(bits: u64) callconv(.c) u64;

fn require(ok: bool, label: []const u8) void {
    if (!ok) {
        pulp.print("simd-probe: FAIL {s}\n", .{label});
        pulp.exit(1);
    }
}

export fn simdProbeMain() callconv(.c) noreturn {
    require(simd_initial[0] == 0x7f and simd_initial[1] == 3 and simd_initial[4] == 0, "clean x87 environment");
    require(simd_initial[24] == 0x80 and simd_initial[25] == 0x1f, "clean MXCSR");
    for (simd_initial[160..416]) |b| require(b == 0, "new process inherited XMM data");
    var expected: [512]u8 align(16) = [_]u8{0} ** 512;
    var result: [512]u8 align(16) = [_]u8{0} ** 512;
    const pid: u64 = @intCast(pulp.getpid());
    expected[0] = 0x7f;
    expected[1] = @intCast(3 | ((pid & 3) << 2)); // distinct rounding modes
    expected[4] = 0xff; // all eight x87 registers contain valid normal values
    expected[24] = 0x80;
    expected[25] = @intCast(0x1f | ((pid & 3) << 5));
    for (0..8) |i| {
        const at = 32 + i * 16;
        expected[at] = @truncate(pid + i);
        expected[at + 7] = 0x80;
        expected[at + 8] = 0xff;
        expected[at + 9] = 0x3f;
    }
    for (160..416) |i| expected[i] = @truncate(pid * 17 + i);
    var cpu_mask: u64 = 0;
    require(simdStress(&expected, &result, 128, &cpu_mask) == 0, "x87/XMM/MXCSR changed across scheduling");
    require(simdArithmetic(0x4008000000000000) == 0x4018000000000000, "SSE2 double arithmetic");
    pulp.print("simd-probe: PASS pid={d} cpus={x} x87/XMM/MXCSR and SSE2 arithmetic\n", .{ pid, cpu_mask });
    pulp.exit(0);
}
