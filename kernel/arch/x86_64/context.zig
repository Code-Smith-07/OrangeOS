//! Kernel-thread context switching.
//!
//! Only callee-saved registers are switched. Everything else is already on the
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
pub extern fn contextSwitch(old_rsp: *u64, new_rsp: u64) callconv(.c) void;

/// Switch to `new_rsp` without saving anything. Used once, to start the first
/// thread from the boot context, which is never resumed.
pub extern fn contextStart(new_rsp: u64) callconv(.c) noreturn;

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
