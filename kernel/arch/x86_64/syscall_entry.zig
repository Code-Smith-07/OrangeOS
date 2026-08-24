//! SYSCALL/SYSRET entry.
//!
//! `syscall` is fast because it does almost nothing: it loads CS/SS from an
//! MSR, puts the return address in rcx and RFLAGS in r11, and jumps. It does
//! NOT switch stacks — we arrive still on the user stack, in ring 0. Finding a
//! kernel stack without trusting user memory is what `swapgs` and the per-CPU
//! block are for.
//!
//! Register discipline, forced by the instruction itself:
//!   rcx = user return address   (so arg3 lives in r10, not rcx)
//!   r11 = user RFLAGS
//!
//! MSR_STAR encodes the selectors. SYSRET computes SS = STAR[63:48] + 8 and
//! CS = STAR[63:48] + 16, which is exactly why the GDT was laid out
//! kcode, kdata, udata, ucode back in Phase 1.

const gdt = @import("gdt.zig");
const syscall = @import("../../syscall/syscall.zig");

// The assembly above calls syscallDispatch by symbol name, which is not a
// reference Zig can see. Without this, the module is never compiled and the
// link fails with an undefined symbol.
comptime {
    _ = syscall;
}

const IA32_EFER: u32 = 0xC000_0080;
const IA32_STAR: u32 = 0xC000_0081;
const IA32_LSTAR: u32 = 0xC000_0082;
const IA32_FMASK: u32 = 0xC000_0084;

const EFER_SCE: u64 = 1 << 0; // SYSCALL enable

comptime {
    asm (
        \\.section .text
        \\.global syscallEntry
        \\.type syscallEntry, @function
        \\syscallEntry:
        \\    swapgs                     
        \\    movq %rsp, %gs:8           
        \\    movq %gs:0, %rsp           
        \\
        \\    # Build a frame matching syscall/SyscallFrame, last field first.
        \\    pushq $0x1b                
        \\    pushq %gs:8                
        \\    pushq %r11                 
        \\    pushq $0x23                
        \\    pushq %rcx                 
        \\
        \\    pushq %rax
        \\    pushq %rbx
        \\    pushq %rcx
        \\    pushq %rdx
        \\    pushq %rsi
        \\    pushq %rdi
        \\    pushq %rbp
        \\    pushq %r8
        \\    pushq %r9
        \\    pushq %r10
        \\    pushq %r11
        \\    pushq %r12
        \\    pushq %r13
        \\    pushq %r14
        \\    pushq %r15
        \\
        \\    movq %rsp, %rdi
        \\    callq syscallDispatch
        \\
        \\    popq %r15
        \\    popq %r14
        \\    popq %r13
        \\    popq %r12
        \\    popq %r11
        \\    popq %r10
        \\    popq %r9
        \\    popq %r8
        \\    popq %rbp
        \\    popq %rdi
        \\    popq %rsi
        \\    popq %rdx
        \\    popq %rcx
        \\    popq %rbx
        \\    popq %rax                  
        \\
        \\    popq %rcx                  
        \\    addq $8, %rsp              
        \\    popq %r11                  
        \\    popq %rsp                  
        \\
        \\    swapgs
        \\    sysretq
        \\.size syscallEntry, . - syscallEntry
    );
}

extern fn syscallEntry() callconv(.c) void;

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

fn readMsr(msr: u32) u64 {
    const low = asm volatile ("rdmsr"
        : [ret] "={eax}" (-> u32),
        : [msr] "{ecx}" (msr),
        : "edx"
    );
    const high = asm volatile ("rdmsr"
        : [ret] "={edx}" (-> u32),
        : [msr] "{ecx}" (msr),
        : "eax"
    );
    return (@as(u64, high) << 32) | low;
}

pub fn init() void {
    // Enable the SYSCALL/SYSRET instruction pair.
    writeMsr(IA32_EFER, readMsr(IA32_EFER) | EFER_SCE);

    // STAR[47:32] = kernel CS (kernel SS is implicitly CS+8).
    // STAR[63:48] = base such that SYSRET gets SS = base+8, CS = base+16.
    const star: u64 = (@as(u64, gdt.KERNEL_CODE) << 32) | (@as(u64, gdt.KERNEL_DATA) << 48);
    writeMsr(IA32_STAR, star);

    // Where syscall jumps to.
    writeMsr(IA32_LSTAR, @intFromPtr(&syscallEntry));

    // Bits cleared in RFLAGS on entry. Clearing IF means we start with
    // interrupts off; leaving direction or trap flags under user control
    // would let a process alter how kernel code executes.
    writeMsr(IA32_FMASK, 0x700); // TF | IF | DF
}
