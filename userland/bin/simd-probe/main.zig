//! Native process-state isolation probe, not a browser executable.
const pulp = @import("pulp");
/// Captured before any Zig code runs: the state a new program starts with.
/// x86: the 512-byte FXSAVE image. Arm: q0-q31, then FPSR and FPCR.
export var simd_initial: [528]u8 align(16) = [_]u8{0} ** 528;
comptime {
    if (pulp.is_arm) {
    asm (
            \\.section .text
            \\.global _start
            \\_start:
            \\    adrp x9, simd_initial
            \\    add x9, x9, :lo12:simd_initial
            \\    stp q0, q1, [x9, #0]
            \\    stp q2, q3, [x9, #32]
            \\    stp q4, q5, [x9, #64]
            \\    stp q6, q7, [x9, #96]
            \\    stp q8, q9, [x9, #128]
            \\    stp q10, q11, [x9, #160]
            \\    stp q12, q13, [x9, #192]
            \\    stp q14, q15, [x9, #224]
            \\    stp q16, q17, [x9, #256]
            \\    stp q18, q19, [x9, #288]
            \\    stp q20, q21, [x9, #320]
            \\    stp q22, q23, [x9, #352]
            \\    stp q24, q25, [x9, #384]
            \\    stp q26, q27, [x9, #416]
            \\    stp q28, q29, [x9, #448]
            \\    stp q30, q31, [x9, #480]
            \\    mrs x10, fpsr
            \\    str x10, [x9, #512]
            \\    mrs x10, fpcr
            \\    str x10, [x9, #520]
            \\    bl simdProbeMain
            \\    udf #0
            \\
            \\.macro simd_load base
            \\    ldp q0, q1, [\base, #0]
            \\    ldp q2, q3, [\base, #32]
            \\    ldp q4, q5, [\base, #64]
            \\    ldp q6, q7, [\base, #96]
            \\    ldp q8, q9, [\base, #128]
            \\    ldp q10, q11, [\base, #160]
            \\    ldp q12, q13, [\base, #192]
            \\    ldp q14, q15, [\base, #224]
            \\    ldp q16, q17, [\base, #256]
            \\    ldp q18, q19, [\base, #288]
            \\    ldp q20, q21, [\base, #320]
            \\    ldp q22, q23, [\base, #352]
            \\    ldp q24, q25, [\base, #384]
            \\    ldp q26, q27, [\base, #416]
            \\    ldp q28, q29, [\base, #448]
            \\    ldp q30, q31, [\base, #480]
            \\    ldr x10, [\base, #512]
            \\    msr fpsr, x10
            \\    ldr x10, [\base, #520]
            \\    msr fpcr, x10
            \\.endm
            \\.macro simd_store base
            \\    stp q0, q1, [\base, #0]
            \\    stp q2, q3, [\base, #32]
            \\    stp q4, q5, [\base, #64]
            \\    stp q6, q7, [\base, #96]
            \\    stp q8, q9, [\base, #128]
            \\    stp q10, q11, [\base, #160]
            \\    stp q12, q13, [\base, #192]
            \\    stp q14, q15, [\base, #224]
            \\    stp q16, q17, [\base, #256]
            \\    stp q18, q19, [\base, #288]
            \\    stp q20, q21, [\base, #320]
            \\    stp q22, q23, [\base, #352]
            \\    stp q24, q25, [\base, #384]
            \\    stp q26, q27, [\base, #416]
            \\    stp q28, q29, [\base, #448]
            \\    stp q30, q31, [\base, #480]
            \\    mrs x10, fpsr
            \\    str x10, [\base, #512]
            \\    mrs x10, fpcr
            \\    str x10, [\base, #520]
            \\.endm
            \\
            \\// simdStress(expected x0, result x1, rounds x2, cpu_mask x3): load every
            \\// vector register and the control word, let the scheduler run other
            \\// programs many times, and check nothing changed.
            \\.global simdStress
            \\simdStress:
            \\    stp x29, x30, [sp, #-208]!
            \\    stp x19, x20, [sp, #16]
            \\    stp x21, x22, [sp, #32]
            \\    stp q8, q9, [sp, #48]
            \\    stp q10, q11, [sp, #80]
            \\    stp q12, q13, [sp, #112]
            \\    stp q14, q15, [sp, #144]
            \\    mrs x10, fpcr
            \\    str x10, [sp, #176]
            \\    mov x19, x0
            \\    mov x20, x1
            \\    mov x21, x2
            \\    mov x22, x3
            \\    simd_load x19
            \\1:
            \\    mov x8, #4
            \\    svc #0
            \\    mov x8, #7
            \\    svc #0
            \\    movz x11, #0xd4c0
            \\    movk x11, #0x1, lsl #16
            \\2:
            \\    subs x11, x11, #1
            \\    b.ne 2b
            \\    mov x8, #61
            \\    mov x0, #1
            \\    svc #0
            \\    mrs x9, tpidrro_el0
            \\    and x9, x9, #63
            \\    mov x10, #1
            \\    lsl x10, x10, x9
            \\    ldr x11, [x22]
            \\    orr x11, x11, x10
            \\    str x11, [x22]
            \\    simd_store x20
            \\    mov x9, #0
            \\3:
            \\    ldr x10, [x19, x9]
            \\    ldr x11, [x20, x9]
            \\    cmp x10, x11
            \\    b.ne 5f
            \\    add x9, x9, #8
            \\    cmp x9, #528
            \\    b.ne 3b
            \\    subs x21, x21, #1
            \\    b.ne 1b
            \\    mov x0, #0
            \\    b 6f
            \\5:
            \\    mov x0, #1
            \\6:
            \\    ldr x10, [sp, #176]
            \\    msr fpcr, x10
            \\    ldp q8, q9, [sp, #48]
            \\    ldp q10, q11, [sp, #80]
            \\    ldp q12, q13, [sp, #112]
            \\    ldp q14, q15, [sp, #144]
            \\    ldp x19, x20, [sp, #16]
            \\    ldp x21, x22, [sp, #32]
            \\    ldp x29, x30, [sp], #208
            \\    ret
            \\
            \\.global simdArithmetic
            \\simdArithmetic:
            \\    fmov d0, x0
            \\    fadd d0, d0, d0
            \\    fmov x0, d0
            \\    ret
        );
    } else {
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
}
extern fn simdStress(expected: *const [528]u8, result: *[528]u8, rounds: u64, cpu_mask: *u64) callconv(.c) u64;
extern fn simdArithmetic(bits: u64) callconv(.c) u64;

fn require(ok: bool, label: []const u8) void {
    if (!ok) {
        pulp.print("simd-probe: FAIL {s}\n", .{label});
        pulp.exit(1);
    }
}

export fn simdProbeMain() callconv(.c) noreturn {
    var expected: [528]u8 align(16) = [_]u8{0} ** 528;
    var result: [528]u8 align(16) = [_]u8{0} ** 528;
    const pid: u64 = @intCast(pulp.getpid());
    if (pulp.is_arm) {
        for (simd_initial) |b| require(b == 0, "new process inherited vector data or control bits");
        for (0..512) |i| expected[i] = @truncate(pid * 17 + i);
        // FPCR: a different rounding mode for each of four programs.
        expected[522] = @intCast((pid & 3) << 6);
    } else {
        require(simd_initial[0] == 0x7f and simd_initial[1] == 3 and simd_initial[4] == 0, "clean x87 environment");
        require(simd_initial[24] == 0x80 and simd_initial[25] == 0x1f, "clean MXCSR");
        for (simd_initial[160..416]) |b| require(b == 0, "new process inherited XMM data");
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
    }
    var cpu_mask: u64 = 0;
    require(simdStress(&expected, &result, 128, &cpu_mask) == 0, if (pulp.is_arm) "vector registers or FPCR changed across scheduling" else "x87/XMM/MXCSR changed across scheduling");
    require(simdArithmetic(0x4008000000000000) == 0x4018000000000000, "double arithmetic");
    pulp.print("simd-probe: PASS pid={d} cpus={x} {s}\n", .{ pid, cpu_mask, if (pulp.is_arm) "q0-q31/FPCR and double arithmetic" else "x87/XMM/MXCSR and SSE2 arithmetic" });
    pulp.exit(0);
}
