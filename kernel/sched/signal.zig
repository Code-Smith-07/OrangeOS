//! POSIX signals, delivered the way Linux does on x86-64.
//!
//! Each program has a disposition per signal (default, ignore, or a handler
//! with its flags, mask and restorer, in Linux's `struct sigaction` layout).
//! Each thread has a blocked mask, signals pending for it alone, and an
//! alternate stack; the program has signals pending for any of its threads.
//!
//! Signals are delivered on the way back to user mode, from a system call or
//! an interrupt. A caught signal gets a Linux-layout frame on the user stack
//! (or the alternate stack): the restorer as return address, a `ucontext`
//! with every register, a `siginfo`, and the FPU state. The handler runs with
//! (sig, &siginfo, &ucontext); returning into the restorer calls `sigreturn`,
//! which restores all of it through the interrupt-return path. A default
//! action ends the program (128 + the signal) or ignores the signal; stopping
//! is not supported and is treated as ignoring. SIGKILL cannot be caught,
//! blocked or ignored.
//!
//! A synchronous fault goes to the program's handler for its signal if there
//! is one and it is not blocked; otherwise the program ends as before.

const std = @import("std");
const sched = @import("sched.zig");
const task_mod = @import("task.zig");
const spinlock = @import("../sync/spinlock.zig");
const validate = @import("../syscall/validate.zig");
const vmm = @import("../mm/vmm.zig");

pub const SIGILL = 4;
pub const SIGTRAP = 5;
pub const SIGABRT = 6;
pub const SIGBUS = 7;
pub const SIGFPE = 8;
pub const SIGKILL = 9;
pub const SIGSEGV = 11;
pub const SIGPIPE = 13;
pub const SIGTERM = 15;
pub const SIGCHLD = 17;
pub const SIGCONT = 18;
pub const SIGSTOP = 19;
pub const SIGTSTP = 20;
pub const SIGTTIN = 21;
pub const SIGTTOU = 22;
pub const SIGURG = 23;
pub const SIGWINCH = 28;
pub const COUNT = 64;

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;
pub const SA_SIGINFO: u64 = 0x4;
pub const SA_ONSTACK: u64 = 0x0800_0000;
pub const SA_RESTART: u64 = 0x1000_0000;
pub const SA_NODEFER: u64 = 0x4000_0000;
pub const SA_RESETHAND: u64 = 0x8000_0000;
pub const SA_RESTORER: u64 = 0x0400_0000;

/// Linux's kernel `struct sigaction` for x86-64.
pub const Action = extern struct {
    handler: u64 = SIG_DFL,
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

pub const AltStack = struct { sp: u64 = 0, size: u64 = 0, disabled: bool = true };

/// Per-program signal state (lives in the process record).
pub const ProcessSignals = struct {
    lock: spinlock.SpinLock = .{},
    actions: [COUNT + 1]Action = [_]Action{.{}} ** (COUNT + 1),
    /// Pending for any thread of the program.
    pending: u64 = 0,
    /// Sender of each pending signal, for siginfo.
    senders: [COUNT + 1]u32 = [_]u32{0} ** (COUNT + 1),
};

pub fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}

/// Signals that can never be blocked.
pub const UNBLOCKABLE: u64 = (@as(u64, 1) << (SIGKILL - 1)) | (@as(u64, 1) << (SIGSTOP - 1));

/// Whether the default action is to ignore (or, for stop signals, which are
/// not supported, to do nothing).
pub fn defaultIgnores(sig: u32) bool {
    return switch (sig) {
        SIGCHLD, SIGCONT, SIGURG, SIGWINCH, SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => true,
        else => false,
    };
}

pub fn actionOf(p: *task_mod.Process, sig: u32) Action {
    const state = spinlock.acquireIrqSave(&p.signals.lock);
    defer spinlock.releaseIrqRestore(&p.signals.lock, state);
    return p.signals.actions[sig];
}

/// Whether a signal would be discarded on arrival (ignored explicitly or by
/// default). SIGKILL never is.
pub fn discarded(p: *task_mod.Process, sig: u32) bool {
    if (sig == SIGKILL) return false;
    const action = actionOf(p, sig);
    return action.handler == SIG_IGN or (action.handler == SIG_DFL and defaultIgnores(sig));
}

pub const ActionError = error{Invalid};

/// sigaction: set and/or read a disposition.
pub fn setAction(p: *task_mod.Process, sig: u32, new: ?Action, old: ?*Action) ActionError!void {
    if (sig == 0 or sig > COUNT) return error.Invalid;
    if (new != null and (sig == SIGKILL or sig == SIGSTOP)) return error.Invalid;
    const state = spinlock.acquireIrqSave(&p.signals.lock);
    defer spinlock.releaseIrqRestore(&p.signals.lock, state);
    if (old) |out| out.* = p.signals.actions[sig];
    if (new) |action| {
        var stored = action;
        stored.mask &= ~UNBLOCKABLE;
        p.signals.actions[sig] = stored;
        // Setting a signal to be ignored discards it if pending (POSIX).
        if (stored.handler == SIG_IGN or (stored.handler == SIG_DFL and defaultIgnores(sig))) {
            _ = @atomicRmw(u64, &p.signals.pending, .And, ~bit(sig), .acq_rel);
        }
    }
}

// ── Frames ──────────────────────────────────────────────────────────────────

/// Linux ucontext (x86-64) as musl lays it out: flags, link, stack_t,
/// mcontext (23 general registers, the FPU-state pointer, 8 reserved words),
/// then a 128-byte signal mask. Padded to 16 bytes.
const UCONTEXT_SIZE = 432;
const SIGINFO_SIZE = 128;
const FPSTATE_SIZE = 512;
const FRAME_SIZE = 8 + UCONTEXT_SIZE + SIGINFO_SIZE + FPSTATE_SIZE;
const GREGS = 40; // offset of gregs within the ucontext
const FPREGS = GREGS + 23 * 8;
const SIGMASK = 8 + 8 + 24 + 256;

// musl's REG_* order.
const REG = struct {
    const R8 = 0;
    const R9 = 1;
    const R10 = 2;
    const R11 = 3;
    const R12 = 4;
    const R13 = 5;
    const R14 = 6;
    const R15 = 7;
    const RDI = 8;
    const RSI = 9;
    const RBP = 10;
    const RBX = 11;
    const RDX = 12;
    const RAX = 13;
    const RCX = 14;
    const RSP = 15;
    const RIP = 16;
    const EFL = 17;
    const CSGSFS = 18;
    const ERR = 19;
    const TRAPNO = 20;
    const OLDMASK = 21;
    const CR2 = 22;
};

pub const Info = struct {
    code: i32 = 0,
    pid: u32 = 0,
    address: u64 = 0,
    trap: u64 = 0,
    error_code: u64 = 0,
    fault: bool = false,
};

const USER_CS: u64 = 0x23;
const USER_SS: u64 = 0x1b;
const RFLAGS_USER_MASK: u64 = 0x0cd5; // CF PF AF ZF SF DF OF
const RFLAGS_IF: u64 = 0x200;

fn put(buffer: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, buffer[offset..][0..8], value, .little);
}

fn get(buffer: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, buffer[offset..][0..8], .little);
}

fn fxsave(out: *[FPSTATE_SIZE]u8) void {
    var state: [FPSTATE_SIZE]u8 align(16) = undefined;
    asm volatile ("fxsave64 (%[state])"
        :
        : [state] "r" (&state),
        : "memory"
    );
    out.* = state;
}

fn fxrstor(in: *const [FPSTATE_SIZE]u8) void {
    var state: [FPSTATE_SIZE]u8 align(16) = in.*;
    asm volatile ("fxrstor64 (%[state])"
        :
        : [state] "r" (&state),
        : "memory"
    );
}

/// Build the frame for a caught signal and point the saved registers at the
/// handler. `frame` is a SyscallFrame or TrapFrame (same register names).
/// Fails if the stack cannot take the frame.
fn setupFrame(frame: anytype, t: *task_mod.Task, sig: u32, action: Action, info: Info) error{Fault}!void {
    // Stack: the alternate one if asked for and not already on it.
    var top = frame.rsp;
    const on_alt = !t.alt_stack.disabled and top > t.alt_stack.sp and top <= t.alt_stack.sp + t.alt_stack.size;
    if (action.flags & SA_ONSTACK != 0 and !t.alt_stack.disabled and !on_alt) {
        top = t.alt_stack.sp + t.alt_stack.size;
    } else {
        top -= 128; // the red zone
    }
    const base = std.mem.alignBackward(u64, top, 16) - FRAME_SIZE;
    const uc_address = base + 8;
    const info_address = uc_address + UCONTEXT_SIZE;
    const fp_address = info_address + SIGINFO_SIZE;

    var image: [FRAME_SIZE]u8 = [_]u8{0} ** FRAME_SIZE;
    put(&image, 0, action.restorer);
    const uc = image[8..][0..UCONTEXT_SIZE];
    // uc_stack describes the alternate stack.
    put(uc, 16, t.alt_stack.sp);
    std.mem.writeInt(u32, uc[24..28], if (t.alt_stack.disabled) 2 else if (on_alt) 1 else 0, .little);
    put(uc, 32, t.alt_stack.size);
    const regs = [_]struct { index: usize, value: u64 }{
        .{ .index = REG.R8, .value = frame.r8 },   .{ .index = REG.R9, .value = frame.r9 },
        .{ .index = REG.R10, .value = frame.r10 }, .{ .index = REG.R11, .value = frame.r11 },
        .{ .index = REG.R12, .value = frame.r12 }, .{ .index = REG.R13, .value = frame.r13 },
        .{ .index = REG.R14, .value = frame.r14 }, .{ .index = REG.R15, .value = frame.r15 },
        .{ .index = REG.RDI, .value = frame.rdi }, .{ .index = REG.RSI, .value = frame.rsi },
        .{ .index = REG.RBP, .value = frame.rbp }, .{ .index = REG.RBX, .value = frame.rbx },
        .{ .index = REG.RDX, .value = frame.rdx }, .{ .index = REG.RAX, .value = frame.rax },
        .{ .index = REG.RCX, .value = frame.rcx }, .{ .index = REG.RSP, .value = frame.rsp },
        .{ .index = REG.RIP, .value = frame.rip }, .{ .index = REG.EFL, .value = frame.rflags },
        .{ .index = REG.CSGSFS, .value = USER_CS }, .{ .index = REG.ERR, .value = info.error_code },
        .{ .index = REG.TRAPNO, .value = info.trap }, .{ .index = REG.OLDMASK, .value = t.sig_blocked },
        .{ .index = REG.CR2, .value = info.address },
    };
    for (regs) |r| put(uc, GREGS + r.index * 8, r.value);
    put(uc, FPREGS, fp_address);
    put(uc, SIGMASK, t.sig_blocked);

    const si = image[8 + UCONTEXT_SIZE ..][0..SIGINFO_SIZE];
    std.mem.writeInt(i32, si[0..4], @intCast(sig), .little);
    std.mem.writeInt(i32, si[8..12], info.code, .little);
    if (info.fault) put(si, 16, info.address) else std.mem.writeInt(u32, si[16..20], info.pid, .little);

    fxsave(image[8 + UCONTEXT_SIZE + SIGINFO_SIZE ..][0..FPSTATE_SIZE]);

    validate.copyToUser(vmm.currentCr3(), base, &image, FRAME_SIZE) catch return error.Fault;

    frame.rip = action.handler;
    frame.rsp = base;
    frame.rdi = sig;
    frame.rsi = info_address;
    frame.rdx = uc_address;
    frame.rax = 0;
    frame.rflags = (frame.rflags & ~@as(u64, 0x500)) | RFLAGS_IF; // clear TF and DF
    frame.cs = USER_CS;
    frame.ss = USER_SS;

    var blocked = t.sig_blocked | action.mask;
    if (action.flags & SA_NODEFER == 0) blocked |= bit(sig);
    t.sig_blocked = blocked & ~UNBLOCKABLE;
}

/// sigreturn: restore what the frame at `uc_address` saved. False if the
/// frame is unreadable or holds values user mode may not have.
pub fn restore(frame: anytype, t: *task_mod.Task, uc_address: u64) bool {
    var uc: [UCONTEXT_SIZE]u8 = undefined;
    validate.copyFromUser(vmm.currentCr3(), &uc, uc_address, UCONTEXT_SIZE) catch return false;
    const rip = get(&uc, GREGS + REG.RIP * 8);
    const rsp = get(&uc, GREGS + REG.RSP * 8);
    if (rip >= validate.USER_MAX or rsp >= validate.USER_MAX) return false;
    var fp: [FPSTATE_SIZE]u8 = undefined;
    const fp_address = get(&uc, FPREGS);
    if (fp_address != 0) {
        validate.copyFromUser(vmm.currentCr3(), &fp, fp_address, FPSTATE_SIZE) catch return false;
        // MXCSR bits outside the CPU's mask would fault fxrstor in the kernel.
        const mxcsr = std.mem.readInt(u32, fp[24..28], .little);
        const mask_saved = std.mem.readInt(u32, fp[28..32], .little);
        const mask = if (mask_saved == 0) @as(u32, 0xffbf) else mask_saved;
        if (mxcsr & ~mask != 0) return false;
    }
    frame.r8 = get(&uc, GREGS + REG.R8 * 8);
    frame.r9 = get(&uc, GREGS + REG.R9 * 8);
    frame.r10 = get(&uc, GREGS + REG.R10 * 8);
    frame.r11 = get(&uc, GREGS + REG.R11 * 8);
    frame.r12 = get(&uc, GREGS + REG.R12 * 8);
    frame.r13 = get(&uc, GREGS + REG.R13 * 8);
    frame.r14 = get(&uc, GREGS + REG.R14 * 8);
    frame.r15 = get(&uc, GREGS + REG.R15 * 8);
    frame.rdi = get(&uc, GREGS + REG.RDI * 8);
    frame.rsi = get(&uc, GREGS + REG.RSI * 8);
    frame.rbp = get(&uc, GREGS + REG.RBP * 8);
    frame.rbx = get(&uc, GREGS + REG.RBX * 8);
    frame.rdx = get(&uc, GREGS + REG.RDX * 8);
    frame.rax = get(&uc, GREGS + REG.RAX * 8);
    frame.rcx = get(&uc, GREGS + REG.RCX * 8);
    frame.rsp = rsp;
    frame.rip = rip;
    frame.rflags = (get(&uc, GREGS + REG.EFL * 8) & RFLAGS_USER_MASK) | RFLAGS_IF | 0x2;
    frame.cs = USER_CS;
    frame.ss = USER_SS;
    t.sig_blocked = get(&uc, SIGMASK) & ~UNBLOCKABLE;
    if (fp_address != 0) fxrstor(&fp);
    return true;
}

// ── Delivery ────────────────────────────────────────────────────────────────

/// Pending signals the current thread could take now.
fn deliverable(t: *task_mod.Task, p: *task_mod.Process) u64 {
    const pending = @atomicLoad(u64, &t.sig_pending, .acquire) | @atomicLoad(u64, &p.signals.pending, .acquire);
    return pending & ~t.sig_blocked;
}

/// Take one deliverable signal off the pending sets; 0 when there is none.
fn take(t: *task_mod.Task, p: *task_mod.Process) struct { sig: u32, sender: u32 } {
    while (true) {
        const ready = deliverable(t, p);
        if (ready == 0) return .{ .sig = 0, .sender = 0 };
        const sig: u32 = @ctz(ready) + 1;
        const b = bit(sig);
        if (@atomicRmw(u64, &t.sig_pending, .And, ~b, .acq_rel) & b != 0) return .{ .sig = sig, .sender = p.pid };
        if (@atomicRmw(u64, &p.signals.pending, .And, ~b, .acq_rel) & b != 0) {
            return .{ .sig = sig, .sender = @atomicLoad(u32, &p.signals.senders[sig], .acquire) };
        }
        // Another thread took it; look again.
    }
}

/// On the way back to user mode: act on pending signals. True when the
/// saved registers now enter a handler and must be restored in full.
/// Default actions that end the program do not return.
pub fn deliver(frame: anytype) bool {
    const t = sched.currentTask() orelse return false;
    const p = t.process orelse return false;
    if (deliverable(t, p) == 0) {
        @atomicStore(bool, &t.sig_interrupt, false, .release);
        return false;
    }
    while (true) {
        const next = take(t, p);
        if (next.sig == 0) {
            @atomicStore(bool, &t.sig_interrupt, false, .release);
            return false;
        }
        const action = actionOf(p, next.sig);
        if (action.handler == SIG_IGN) continue;
        if (action.handler == SIG_DFL) {
            if (defaultIgnores(next.sig)) continue;
            sched.exitGroup(128 + @as(i32, @intCast(next.sig)));
        }
        if (action.flags & SA_RESETHAND != 0) {
            const state = spinlock.acquireIrqSave(&p.signals.lock);
            p.signals.actions[next.sig] = .{};
            spinlock.releaseIrqRestore(&p.signals.lock, state);
        }
        setupFrame(frame, t, next.sig, action, .{ .code = 0, .pid = next.sender }) catch sched.exitGroup(128 + SIGSEGV);
        @atomicStore(bool, &t.sig_interrupt, false, .release);
        return true;
    }
}

/// A synchronous fault in user mode: if the program handles `sig` and the
/// thread does not block it, enter the handler (true). Otherwise the caller
/// ends the program.
pub fn deliverFault(frame: anytype, sig: u32, info: Info) bool {
    const t = sched.currentTask() orelse return false;
    const p = t.process orelse return false;
    if (t.sig_blocked & bit(sig) != 0) return false;
    const action = actionOf(p, sig);
    if (action.handler == SIG_DFL or action.handler == SIG_IGN) return false;
    if (action.flags & SA_RESETHAND != 0) {
        const state = spinlock.acquireIrqSave(&p.signals.lock);
        p.signals.actions[sig] = .{};
        spinlock.releaseIrqRestore(&p.signals.lock, state);
    }
    var fault_info = info;
    fault_info.fault = true;
    setupFrame(frame, t, sig, action, fault_info) catch return false;
    return true;
}
