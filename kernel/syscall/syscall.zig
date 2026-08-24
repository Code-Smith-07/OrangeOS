//! Syscall dispatch.
//!
//! The frame layout below must match kernel/arch/x86_64/syscall_entry.zig
//! exactly — the assembly builds it by hand and this struct reads it.

const std = @import("std");
const console = @import("../console.zig");
const sched = @import("../sched/sched.zig");
const validate = @import("validate.zig");
const vmm = @import("../mm/vmm.zig");

/// Register state at the syscall boundary. Field order is the reverse of the
/// push order in syscallEntry.
pub const SyscallFrame = extern struct {
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
    // Pushed by the entry stub to mirror an interrupt frame.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const Nr = enum(u64) {
    exit = 0,
    write = 1,
    getpid = 4,
    yield = 7,
    uptime = 60,
    _,
};

/// Negative return values are -errno, matching the ABI documented in
/// ARCHITECTURE.md §11.
const EFAULT: i64 = -14;
const ENOSYS: i64 = -38;
const EBADF: i64 = -9;

var syscall_count: u64 = 0;

/// The single entry point from assembly.
export fn syscallDispatch(frame: *SyscallFrame) callconv(.c) void {
    syscall_count += 1;

    // Arguments: rdi, rsi, rdx, r10, r8, r9. Note r10, not rcx — the syscall
    // instruction clobbers rcx with the return address.
    const result: i64 = switch (@as(Nr, @enumFromInt(frame.rax))) {
        .exit => sysExit(@bitCast(frame.rdi)),
        .write => sysWrite(frame.rdi, frame.rsi, frame.rdx),
        .getpid => sysGetpid(),
        .yield => sysYield(),
        .uptime => sysUptime(),
        else => ENOSYS,
    };

    frame.rax = @bitCast(result);
}

fn sysExit(code: i64) i64 {
    console.print("[info] user process exited with code {d}\n", .{code});
    sched.exit(@truncate(code));
}

fn sysWrite(fd: u64, buf: u64, len: u64) i64 {
    if (fd != 1 and fd != 2) return EBADF;
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;

    const pml4 = vmm.currentCr3();

    var kbuf: [4096]u8 = undefined;
    validate.copyFromUser(pml4, &kbuf, buf, @intCast(len)) catch return EFAULT;

    console.write(kbuf[0..@intCast(len)]);
    return @intCast(len);
}

fn sysGetpid() i64 {
    const t = sched.currentTask() orelse return -1;
    return @intCast(t.tid);
}

fn sysYield() i64 {
    sched.yield();
    return 0;
}

fn sysUptime() i64 {
    const time = @import("../time/time.zig");
    return @intCast(time.millisSinceBoot());
}

pub fn count() u64 {
    return syscall_count;
}
