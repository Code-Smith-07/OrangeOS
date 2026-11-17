//! Interrupts, system calls and faults on Arm64.
//!
//! vectors.S saves the registers and calls exceptionEntry with the frame
//! and the vector slot. From there:
//!   - an interrupt goes to the handler registered for its number;
//!   - `svc` from a program is a system call;
//!   - a fault in a program is resolved (a page not yet brought in), handed
//!     to the program's signal handler, or ends the program;
//!   - anything unexpected in the kernel itself is a panic.

const std = @import("std");
const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const apic = @import("apic.zig");
const smp = @import("smp.zig");
const console = @import("../../console.zig");
const fmt = @import("../../lib/fmt.zig");
const backtrace = @import("../../debug/backtrace.zig");
const syscall = @import("../../syscall/syscall.zig");

/// The registers vectors.S saves, in the order it saves them.
pub const TrapFrame = extern struct {
    x: [31]u64,
    pc: u64,
    pstate: u64,
    /// The program's stack pointer (the kernel has its own).
    sp: u64,

    /// Argument `n` of a system call: x0 to x5.
    pub inline fn arg(self: *const TrapFrame, comptime n: u3) u64 {
        return self.x[n];
    }
    /// Which call the program asked for: x8, as on Linux.
    pub inline fn number(self: *const TrapFrame) u64 {
        return self.x[8];
    }
    pub inline fn setResult(self: *TrapFrame, value: u64) void {
        self.x[0] = value;
    }
    pub inline fn fromUser(self: *const TrapFrame) bool {
        return self.pstate & 0xF == 0;
    }
};

extern const exception_vectors: u8;

/// On every processor.
pub fn install() void {
    cpu.write("vbar_el1", @intFromPtr(&exception_vectors));
    cpu.isb();
}

pub const HandlerFn = *const fn (*TrapFrame) void;
var handlers: [256]?HandlerFn = [_]?HandlerFn{null} ** 256;

/// `vector` is a GIC interrupt number: 0-15 between processors, 16-31
/// private to a processor (the timer is 27), 32 and up from devices.
pub fn register(vector: u8, handler: HandlerFn) void {
    handlers[vector] = handler;
}

const CLASS_UNKNOWN = 0x00;
const CLASS_SYSTEM_CALL = 0x15;
const CLASS_INSTRUCTION_ABORT_USER = 0x20;
const CLASS_INSTRUCTION_ABORT = 0x21;
const CLASS_PC_ALIGNMENT = 0x22;
const CLASS_DATA_ABORT_USER = 0x24;
const CLASS_DATA_ABORT = 0x25;
const CLASS_SP_ALIGNMENT = 0x26;
const CLASS_FLOATING_POINT = 0x2C;
const CLASS_BREAKPOINT = 0x3C;

fn className(class: u64) []const u8 {
    return switch (class) {
        CLASS_UNKNOWN => "unknown instruction",
        0x07 => "floating point used while switched off",
        CLASS_SYSTEM_CALL => "system call",
        CLASS_INSTRUCTION_ABORT_USER, CLASS_INSTRUCTION_ABORT => "instruction fetch from a bad address",
        CLASS_PC_ALIGNMENT => "misaligned program counter",
        CLASS_DATA_ABORT_USER, CLASS_DATA_ABORT => "data access to a bad address",
        CLASS_SP_ALIGNMENT => "misaligned stack pointer",
        CLASS_FLOATING_POINT => "floating point exception",
        CLASS_BREAKPOINT => "breakpoint",
        else => "other",
    };
}

export fn exceptionEntry(frame: *TrapFrame, slot: u64) callconv(.c) void {
    switch (slot) {
        5, 9 => interrupt(frame),
        8 => {
            const syndrome = cpu.read("esr_el1");
            if (syndrome >> 26 == CLASS_SYSTEM_CALL) {
                _ = syscall.syscallDispatch(frame);
            } else userFault(frame, syndrome);
        },
        else => crash(frame, slot, cpu.read("esr_el1")),
    }
}

fn interrupt(frame: *TrapFrame) void {
    const number = gic.acknowledge();
    if (number >= 1020) return; // nothing was waiting
    if (number == apic.VECTOR_TIMER) apic.rearm();
    // Before the handler, not after: the timer handler may switch threads
    // and not come back here for a long time.
    gic.done(number);
    if (number >= 16) @import("../../lib/random.zig").mixInterrupt(@truncate(number));
    if (number < 256 and handlers[number] != null) {
        handlers[number].?(frame);
    } else {
        console.print("[warn] unhandled interrupt {d}\n", .{number});
    }
    if (frame.fromUser()) finishUserReturn(frame);
}

/// A thread of an exiting program never returns to it; pending signals are
/// delivered on the way back.
fn finishUserReturn(frame: *TrapFrame) void {
    const sched = @import("../../sched/sched.zig");
    if (sched.killPending()) sched.exit(0);
    _ = @import("../../sched/signal.zig").deliver(frame);
}

fn userFault(frame: *TrapFrame, syndrome: u64) void {
    const sched = @import("../../sched/sched.zig");
    const signal = @import("../../sched/signal.zig");
    const user_vm = @import("../../mm/user_vm.zig");
    const class = syndrome >> 26;
    const address = cpu.read("far_el1");
    const is_abort = class == CLASS_INSTRUCTION_ABORT_USER or class == CLASS_DATA_ABORT_USER;
    // Fault status 0b0001xx: no translation, at some level of the walk.
    const not_mapped = syndrome & 0x3C == 0x04;

    if (is_abort and not_mapped) {
        if (sched.currentTask()) |task| {
            if (task.user_space) |space| {
                const access: user_vm.Access = if (class == CLASS_INSTRUCTION_ABORT_USER) .execute else if (syndrome & (1 << 6) != 0) .write else .read;
                // From a program no kernel lock is held, and the VM lock needs
                // interrupts on: another processor holding it may be waiting
                // for this one to answer a TLB shootdown (as on x86).
                cpu.interruptsOn();
                const resolved = user_vm.faultIn(space, address, access);
                cpu.interruptsOff();
                if (resolved) {
                    @import("mmu.zig").syncInstructions();
                    if (sched.killPending()) sched.exit(0);
                    return;
                }
            }
        }
    }

    // The same numbers an x86 program would see, so exit statuses and
    // signal details do not depend on the processor.
    const Kind = struct { vector: u8, sig: u32, code: i32 };
    const kind: Kind = switch (class) {
        CLASS_INSTRUCTION_ABORT_USER, CLASS_DATA_ABORT_USER => .{ .vector = 14, .sig = signal.SIGSEGV, .code = if (not_mapped) 1 else 2 },
        CLASS_UNKNOWN => .{ .vector = 6, .sig = signal.SIGILL, .code = 1 },
        CLASS_PC_ALIGNMENT, CLASS_SP_ALIGNMENT => .{ .vector = 17, .sig = signal.SIGBUS, .code = 1 },
        CLASS_FLOATING_POINT => .{ .vector = 19, .sig = signal.SIGFPE, .code = 0 },
        CLASS_BREAKPOINT => .{ .vector = 3, .sig = signal.SIGTRAP, .code = 1 },
        else => .{ .vector = 6, .sig = signal.SIGILL, .code = 1 },
    };
    const info: signal.Info = .{ .trap = kind.vector, .error_code = syndrome, .address = if (is_abort) address else frame.pc, .code = kind.code };
    if (signal.deliverFault(frame, kind.sig, info)) {
        if (sched.killPending()) sched.exit(0);
        return;
    }
    if (sched.currentTask()) |t| {
        console.print("[app fault] pid {d} tid {d} {s}: {s} at 0x{x} touching 0x{x} (syndrome 0x{x})\n", .{
            t.ownerId(), t.tid, t.nameSlice(), className(class), frame.pc, address, syndrome,
        });
        sched.exitGroup(128 + @as(i32, kind.vector));
    }
    crash(frame, 8, syndrome);
}

fn crash(frame: *TrapFrame, slot: u64, syndrome: u64) noreturn {
    @branchHint(.cold);
    cpu.interruptsOff();
    smp.haltOtherCpus();
    var line: [200]u8 = undefined;
    console.emergencyWrite(fmt.bufPrint(&line, "\nKERNEL PANIC (arm64): {s}\n", .{className(syndrome >> 26)}));
    console.emergencyWrite(fmt.bufPrint(&line, "  vector {d}, syndrome 0x{x}, address touched 0x{x:0>16}\n", .{ slot, syndrome, cpu.read("far_el1") }));
    console.emergencyWrite(fmt.bufPrint(&line, "  at 0x{x:0>16}, called from 0x{x:0>16}, state 0x{x}, sp 0x{x:0>16}\n", .{ frame.pc, frame.x[30], frame.pstate, @intFromPtr(frame) + @sizeOf(TrapFrame) }));
    backtrace.emergency(frame.x[29]);
    console.emergencyWrite("  System halted.\n");
    while (true) cpu.waitForInterrupt();
}
