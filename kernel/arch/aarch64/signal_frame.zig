//! Signal frames on Arm64.
//!
//! When a program catches a signal, its registers are written to its own
//! stack in the layout Linux and musl define for Arm64 (siginfo, then a
//! ucontext with the general registers and an "fpsimd" record), and the
//! saved registers are pointed at the handler. `sigreturn` reads the frame
//! back. x86's version of this is in sched/signal.zig.

const std = @import("std");
const fpu = @import("fpu.zig");
const isr = @import("isr.zig");
const signal = @import("../../sched/signal.zig");
const task_mod = @import("../../sched/task.zig");
const validate = @import("../../syscall/validate.zig");
const vmm = @import("../../mm/vmm.zig");

const SIGINFO_SIZE = 128;
// ucontext: flags, link, the alternate stack (24 bytes), the signal mask
// (128 bytes), then the machine context, 16-byte aligned.
const UC_STACK = 16;
const UC_SIGMASK = 40;
const UC_MCONTEXT = 176;
const MC_FAULT_ADDRESS = UC_MCONTEXT;
const MC_REGS = UC_MCONTEXT + 8; // x0 to x30
const MC_SP = MC_REGS + 31 * 8;
const MC_PC = MC_SP + 8;
const MC_PSTATE = MC_PC + 8;
const MC_RESERVED = UC_MCONTEXT + 288; // records, each with a magic and a size
const FPSIMD_MAGIC: u32 = 0x4650_8001;
const FPSIMD_SIZE = 528; // header, FPSR, FPCR, 32 registers of 16 bytes
const UCONTEXT_SIZE = MC_RESERVED + 4096;
const FRAME_SIZE = SIGINFO_SIZE + UCONTEXT_SIZE;
/// Only the condition flags of the saved state belong to the program.
const PSTATE_USER_MASK: u64 = 0xF000_0000;

fn put(buffer: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, buffer[offset..][0..8], value, .little);
}
fn get(buffer: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, buffer[offset..][0..8], .little);
}

// The frame is too large for a kernel stack and is built with interrupts
// off on the way back to the program, so one buffer per processor will do.
const percpu = @import("percpu.zig");
var images: [percpu.MAX_CPUS][FRAME_SIZE]u8 = undefined;

pub fn setupFrame(frame: *isr.TrapFrame, t: *task_mod.Task, sig: u32, action: signal.Action, info: signal.Info) error{Fault}!void {
    var top = frame.sp;
    const on_alt = !t.alt_stack.disabled and top > t.alt_stack.sp and top <= t.alt_stack.sp + t.alt_stack.size;
    if (action.flags & signal.SA_ONSTACK != 0 and !t.alt_stack.disabled and !on_alt) {
        top = t.alt_stack.sp + t.alt_stack.size;
    }
    const base = std.mem.alignBackward(u64, top, 16) - FRAME_SIZE;
    const info_address = base;
    const uc_address = base + SIGINFO_SIZE;

    const image = &images[percpu.cpuIndex()];
    @memset(image, 0);
    const si = image[0..SIGINFO_SIZE];
    std.mem.writeInt(i32, si[0..4], @intCast(sig), .little);
    std.mem.writeInt(i32, si[8..12], info.code, .little);
    if (info.fault) put(si, 16, info.address) else std.mem.writeInt(u32, si[16..20], info.pid, .little);

    const uc = image[SIGINFO_SIZE..];
    put(uc, UC_STACK, t.alt_stack.sp);
    std.mem.writeInt(u32, uc[UC_STACK + 8 ..][0..4], if (t.alt_stack.disabled) 2 else if (on_alt) 1 else 0, .little);
    put(uc, UC_STACK + 16, t.alt_stack.size);
    put(uc, UC_SIGMASK, t.sig_blocked);
    put(uc, MC_FAULT_ADDRESS, if (info.fault) info.address else 0);
    for (frame.x, 0..) |value, n| put(uc, MC_REGS + n * 8, value);
    put(uc, MC_SP, frame.sp);
    put(uc, MC_PC, frame.pc);
    put(uc, MC_PSTATE, frame.pstate);

    var fp: fpu.State = undefined;
    fpu.save(&fp);
    const record = uc[MC_RESERVED..];
    std.mem.writeInt(u32, record[0..4], FPSIMD_MAGIC, .little);
    std.mem.writeInt(u32, record[4..8], FPSIMD_SIZE, .little);
    std.mem.writeInt(u32, record[8..12], @truncate(fp.fpsr), .little);
    std.mem.writeInt(u32, record[12..16], @truncate(fp.fpcr), .little);
    @memcpy(record[16..][0..512], std.mem.asBytes(&fp.q));
    // The next record's zero magic ends the list (the buffer is zeroed).

    validate.copyToUser(vmm.currentCr3(), base, image, FRAME_SIZE) catch return error.Fault;

    frame.pc = action.handler;
    frame.sp = base;
    frame.x[0] = sig;
    frame.x[1] = info_address;
    frame.x[2] = uc_address;
    frame.x[30] = action.restorer; // where the handler returns to
    frame.pstate &= PSTATE_USER_MASK;

    var blocked = t.sig_blocked | action.mask;
    if (action.flags & signal.SA_NODEFER == 0) blocked |= signal.bit(sig);
    t.sig_blocked = blocked & ~signal.UNBLOCKABLE;
}

/// sigreturn: restore what the frame at `uc_address` saved. False if the
/// frame is unreadable or holds values a program may not have.
pub fn restore(frame: *isr.TrapFrame, t: *task_mod.Task, uc_address: u64) bool {
    const image = &images[percpu.cpuIndex()];
    const uc = image[0..UCONTEXT_SIZE];
    validate.copyFromUser(vmm.currentCr3(), uc, uc_address, UCONTEXT_SIZE) catch return false;
    const pc = get(uc, MC_PC);
    const sp = get(uc, MC_SP);
    if (pc >= validate.USER_MAX or sp >= validate.USER_MAX) return false;

    for (&frame.x, 0..) |*slot, n| slot.* = get(uc, MC_REGS + n * 8);
    frame.sp = sp;
    frame.pc = pc;
    // User level, interrupts on; only the condition flags are the program's.
    frame.pstate = get(uc, MC_PSTATE) & PSTATE_USER_MASK;
    t.sig_blocked = get(uc, UC_SIGMASK) & ~signal.UNBLOCKABLE;

    const record = uc[MC_RESERVED..];
    if (std.mem.readInt(u32, record[0..4], .little) == FPSIMD_MAGIC) {
        var fp: fpu.State = .{};
        fp.fpsr = std.mem.readInt(u32, record[8..12], .little);
        fp.fpcr = std.mem.readInt(u32, record[12..16], .little);
        @memcpy(std.mem.asBytes(&fp.q), record[16..][0..512]);
        fpu.load(&fp);
    }
    return true;
}
