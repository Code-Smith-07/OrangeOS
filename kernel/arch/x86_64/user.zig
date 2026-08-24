//! Ring 3 entry.
//!
//! There is no instruction that simply "enters user mode". The way in is to
//! fabricate the stack frame an interrupt would have pushed on the way out of
//! ring 3, then execute `iretq` — the CPU restores CS, SS, RFLAGS, RIP and RSP
//! from that frame and lands in user mode.

const gdt = @import("gdt.zig");

/// Selector | RPL 3. The CPU checks the requested privilege level in the low
/// two bits, so a ring-3 selector must carry them.
pub const USER_CODE_SEL: u64 = gdt.USER_CODE | 3;
pub const USER_DATA_SEL: u64 = gdt.USER_DATA | 3;

/// RFLAGS for a fresh user thread: bit 1 is reserved and must be set, bit 9
/// (IF) enables interrupts so the thread can be preempted.
const USER_RFLAGS: u64 = 0x202;

comptime {
    asm (
        \\.section .text
        \\.global enterUserMode
        \\.type enterUserMode, @function
        \\enterUserMode:
        \\    # rdi = entry rip, rsi = user rsp, rdx = user cs, rcx = user ss, r8 = rflags
        \\    pushq %rcx
        \\    pushq %rsi
        \\    pushq %r8
        \\    pushq %rdx
        \\    pushq %rdi
        \\
        \\    # Clear every register that would otherwise leak kernel data
        \\    # into ring 3.
        \\    xorq %rax, %rax
        \\    xorq %rbx, %rbx
        \\    xorq %rcx, %rcx
        \\    xorq %rdx, %rdx
        \\    xorq %rsi, %rsi
        \\    xorq %rdi, %rdi
        \\    xorq %rbp, %rbp
        \\    xorq %r8,  %r8
        \\    xorq %r9,  %r9
        \\    xorq %r10, %r10
        \\    xorq %r11, %r11
        \\    xorq %r12, %r12
        \\    xorq %r13, %r13
        \\    xorq %r14, %r14
        \\    xorq %r15, %r15
        \\
        \\    # Kernel runs with GS_BASE = &percpu. Crossing into ring 3 has to
        \\    # move that into KERNEL_GS_BASE so the next syscall's swapgs
        \\    # finds it. Without this, the first syscall from a freshly
        \\    # spawned process faults writing to gs:8 with a null GS.
        \\    swapgs
        \\    iretq
        \\.size enterUserMode, . - enterUserMode
    );
}

extern fn enterUserMode(rip: u64, rsp: u64, cs: u64, ss: u64, rflags: u64) callconv(.c) noreturn;

/// Drop to ring 3 at `entry` with `stack`. Never returns.
pub fn enter(entry: u64, stack: u64) noreturn {
    enterUserMode(entry, stack, USER_CODE_SEL, USER_DATA_SEL, USER_RFLAGS);
}
