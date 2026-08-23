//! Exception and interrupt entry.
//!
//! Every vector gets a small naked stub that normalizes the stack (pushing a
//! dummy error code where the CPU doesn't supply one, then the vector number)
//! and jumps to one common path that saves all general-purpose registers and
//! calls into Zig.
//!
//! The stubs are generated at comptime rather than written in a .S file, so the
//! vector table and the entry code can never drift apart.

const std = @import("std");
const console = @import("../../console.zig");
const panic_mod = @import("../../panic.zig");

/// Register state at the point of the trap.
///
/// Field order is the reverse of push order, since the stack grows downward and
/// `rsp` points at the last thing pushed.
pub const TrapFrame = extern struct {
    // Pushed by isrCommon, last push first.
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Pushed by the per-vector stub.
    vector: u64,
    error_code: u64,
    // Pushed by the CPU.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const EXCEPTION_COUNT = 32;

pub const exception_names = [EXCEPTION_COUNT][]const u8{
    "divide error", // 0  #DE
    "debug", // 1  #DB
    "non-maskable interrupt", // 2  NMI
    "breakpoint", // 3  #BP
    "overflow", // 4  #OF
    "bound range exceeded", // 5  #BR
    "invalid opcode", // 6  #UD
    "device not available", // 7  #NM
    "double fault", // 8  #DF
    "coprocessor segment overrun", // 9
    "invalid TSS", // 10 #TS
    "segment not present", // 11 #NP
    "stack-segment fault", // 12 #SS
    "general protection fault", // 13 #GP
    "page fault", // 14 #PF
    "reserved (15)", // 15
    "x87 floating-point error", // 16 #MF
    "alignment check", // 17 #AC
    "machine check", // 18 #MC
    "SIMD floating-point error", // 19 #XM
    "virtualization exception", // 20 #VE
    "control protection exception", // 21 #CP
    "reserved (22)",
    "reserved (23)",
    "reserved (24)",
    "reserved (25)",
    "reserved (26)",
    "reserved (27)",
    "hypervisor injection", // 28 #HV
    "VMM communication", // 29 #VC
    "security exception", // 30 #SX
    "reserved (31)",
};

/// Vectors where the CPU pushes an error code itself. Everything else needs a
/// dummy pushed so the frame layout is uniform.
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Saves all GP registers, hands a *TrapFrame to Zig, restores, and returns.
export fn isrCommon() callconv(.naked) void {
    asm volatile (
        \\ pushq %rax
        \\ pushq %rbx
        \\ pushq %rcx
        \\ pushq %rdx
        \\ pushq %rsi
        \\ pushq %rdi
        \\ pushq %rbp
        \\ pushq %r8
        \\ pushq %r9
        \\ pushq %r10
        \\ pushq %r11
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\
        \\ movq %rsp, %rdi
        \\ callq isrDispatch
        \\
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %r11
        \\ popq %r10
        \\ popq %r9
        \\ popq %r8
        \\ popq %rbp
        \\ popq %rdi
        \\ popq %rsi
        \\ popq %rdx
        \\ popq %rcx
        \\ popq %rbx
        \\ popq %rax
        \\
        \\ addq $16, %rsp
        \\ iretq
    );
}

/// One naked stub per vector, generated at comptime.
fn stub(comptime vector: u8) fn () callconv(.naked) void {
    // Built out here: a naked function body may contain nothing but asm, so
    // the string has to be fully resolved before we get inside it.
    const entry_asm = comptime blk: {
        const dummy = if (hasErrorCode(vector)) "" else "pushq $0\n";
        break :blk std.fmt.comptimePrint(
            "{s}pushq ${d}\njmp isrCommon",
            .{ dummy, vector },
        );
    };
    return struct {
        fn entry() callconv(.naked) void {
            asm volatile (entry_asm);
        }
    }.entry;
}

/// Address of each vector's entry point, for the IDT to point at.
pub fn stubAddress(comptime vector: u8) u64 {
    return @intFromPtr(&stub(vector));
}

pub const HandlerFn = *const fn (*TrapFrame) void;

/// Optional per-vector overrides. Phase 3 registers timer and device IRQs here.
var handlers: [256]?HandlerFn = [_]?HandlerFn{null} ** 256;

pub fn register(vector: u8, handler: HandlerFn) void {
    handlers[vector] = handler;
}

/// #BP is a debugging aid, not a fatal fault: report and resume.
fn breakpointHandler(frame: *TrapFrame) void {
    console.print("[info] breakpoint at 0x{x:0>16}\n", .{frame.rip});
}

/// Install handlers for exceptions that should not be fatal.
pub fn installDefaults() void {
    register(3, breakpointHandler);
}

/// The single Zig entry point for every trap.
export fn isrDispatch(frame: *TrapFrame) callconv(.c) void {
    const vec: u8 = @truncate(frame.vector);

    if (handlers[vec]) |h| {
        h(frame);
        return;
    }

    if (vec < EXCEPTION_COUNT) {
        panic_mod.exception(frame);
    }

    // Unhandled non-exception vector: report and continue.
    console.print("[warn] unhandled interrupt vector {d}\n", .{vec});
}

/// Read CR2, which holds the faulting address for a page fault.
pub fn readCr2() u64 {
    return asm volatile ("movq %%cr2, %[out]"
        : [out] "=r" (-> u64),
    );
}

pub fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

pub fn readCr0() u64 {
    return asm volatile ("movq %%cr0, %[out]"
        : [out] "=r" (-> u64),
    );
}

pub fn readCr4() u64 {
    return asm volatile ("movq %%cr4, %[out]"
        : [out] "=r" (-> u64),
    );
}
