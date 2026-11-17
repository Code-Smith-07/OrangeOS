//! Kernel-thread context switching.
//!
//! General callee-saved registers plus eager x87/MMX/SSE state are switched.
//! Other general registers are already on the
//! stack: a preempted thread got there through the interrupt path, which saved
//! its full register set into a TrapFrame on its own kernel stack, and a
//! voluntarily yielding thread has whatever the C ABI says is scratch.
//!
//! Because each thread owns its kernel stack, switching stacks switches
//! execution: the `ret` at the end lands wherever the new thread's stack says
//! it should.
//!
//! These are emitted as global assembly rather than Zig `callconv(.naked)`
//! functions, because a naked function cannot be called from Zig — only jumped
//! to. Global asm gives a real symbol that an `extern` declaration can call.

comptime {
    asm (
        \\.section .text
        \\
        \\.global contextSwitch
        \\.type contextSwitch, @function
        \\contextSwitch:
        \\    fxsave64 (%rdx)
        \\    fxrstor64 (%rcx)
        \\    pushq %rbp
        \\    pushq %rbx
        \\    pushq %r12
        \\    pushq %r13
        \\    pushq %r14
        \\    pushq %r15
        \\
        \\    movq %rsp, (%rdi)
        \\    movq %rsi, %rsp
        \\
        \\    popq %r15
        \\    popq %r14
        \\    popq %r13
        \\    popq %r12
        \\    popq %rbx
        \\    popq %rbp
        \\    retq
        \\.size contextSwitch, . - contextSwitch
        \\
        \\.global contextStart
        \\.type contextStart, @function
        \\contextStart:
        \\    fxrstor64 (%rsi)
        \\    movq %rdi, %rsp
        \\    popq %r15
        \\    popq %r14
        \\    popq %r13
        \\    popq %r12
        \\    popq %rbx
        \\    popq %rbp
        \\    retq
        \\.size contextStart, . - contextStart
    );
}

/// Callee-saved state, in the exact order contextSwitch pushes it.
/// The layout is load-bearing: `prepareStack` fabricates it by hand for
/// threads that have never run.
pub const Context = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rip: u64 = 0, // consumed by `ret`
};

/// Save the current stack pointer into `old_rsp`, switch to `new_rsp`, and
/// resume whatever is there. Arguments arrive in rdi/rsi per the SysV ABI.
pub extern fn contextSwitch(old_rsp: *u64, new_rsp: u64, old_fpu: *@import("fpu.zig").State, new_fpu: *const @import("fpu.zig").State) callconv(.c) void;

/// Restore the next task without saving the discarded boot/exiting context.
pub extern fn contextStart(new_rsp: u64, new_fpu: *const @import("fpu.zig").State) callconv(.c) noreturn;

/// Build a stack for a thread that has never run, so the first
/// `contextSwitch` into it lands at `entry`.
pub fn prepareStack(stack_top: u64, entry: u64) u64 {
    // 16-byte align, then bias by 8. The SysV ABI wants rsp+8 to be 16-byte
    // aligned at a function's entry, because a normal `call` would have pushed
    // a return address. `ret` does not, so we account for it here.
    var sp = (stack_top & ~@as(u64, 0xF)) - 8;

    sp -= @sizeOf(Context);
    const ctx: *Context = @ptrFromInt(sp);
    ctx.* = .{ .rip = entry };

    return sp;
}

/// For the scheduler's self-test: fill the registers a function must
/// preserve with known values, spin long enough to be preempted many times,
/// and report whether every value is still there.
pub fn registersSurvivePreemption() bool {
    // Note on the comparisons below: x86-64 `cmpq` has no 64-bit immediate
    // form, so each magic value is reloaded into a scratch register with
    // `movabsq` and compared register-to-register. Writing
    // `cmpq $0xB0B0..., %rbx` assembles nowhere.
    var ok: u64 = 0;
    asm volatile (
        \\ movabsq $0xB0B0B0B0B0B0B0B0, %rbx
        \\ movabsq $0x1212121212121212, %r12
        \\ movabsq $0x1313131313131313, %r13
        \\ movabsq $0x1414141414141414, %r14
        \\ movabsq $0x1515151515151515, %r15
        \\
        \\ # Spin long enough that the timer preempts us many times.
        \\ movq $30000000, %rcx
        \\ 1:
        \\ decq %rcx
        \\ jnz 1b
        \\
        \\ # Every register must still hold what we put there.
        \\ xorq %rax, %rax
        \\ movabsq $0xB0B0B0B0B0B0B0B0, %rdx
        \\ cmpq %rdx, %rbx
        \\ jne 2f
        \\ movabsq $0x1212121212121212, %rdx
        \\ cmpq %rdx, %r12
        \\ jne 2f
        \\ movabsq $0x1313131313131313, %rdx
        \\ cmpq %rdx, %r13
        \\ jne 2f
        \\ movabsq $0x1414141414141414, %rdx
        \\ cmpq %rdx, %r14
        \\ jne 2f
        \\ movabsq $0x1515151515151515, %rdx
        \\ cmpq %rdx, %r15
        \\ jne 2f
        \\ movq $1, %rax
        \\ 2:
        : [out] "={rax}" (ok),
        :
        : "rbx", "rcx", "rdx", "r12", "r13", "r14", "r15", "memory"
    );
    return ok == 1;
}
