//! Per-CPU data, reached through the GS segment base.
//!
//! The syscall entry path has a bootstrapping problem: it arrives on the
//! *user* stack with no free registers and must find a kernel stack without
//! touching user memory. The answer is `swapgs`, which exchanges GS_BASE with
//! KERNEL_GS_BASE in one instruction, after which `%gs:0` reaches this struct.
//!
//! Field offsets are referenced from assembly, so the layout is load-bearing.

const IA32_GS_BASE: u32 = 0xC000_0101;
const IA32_KERNEL_GS_BASE: u32 = 0xC000_0102;

pub const PerCpu = extern struct {
    /// gs:0  — kernel stack to switch to on syscall entry.
    kernel_rsp: u64 = 0,
    /// gs:8  — scratch slot holding the user stack across entry.
    user_rsp: u64 = 0,
    /// gs:16 — currently running task.
    current_task: u64 = 0,
    /// gs:24 — this CPU's LAPIC id.
    cpu_id: u64 = 0,
};

var cpu0: PerCpu = .{};

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

/// Establish the GS invariant:
///
///     in KERNEL mode:  GS_BASE = &percpu,  KERNEL_GS_BASE = user's gs
///     in USER mode:    GS_BASE = user's gs, KERNEL_GS_BASE = &percpu
///
/// `swapgs` at each ring boundary moves between the two. The important half is
/// that GS_BASE is &percpu for ALL kernel code, including kernel threads that
/// never came from userspace — the syscall path can switch threads (sys_wait
/// yields), so a thread can arrive in kernel context without having executed
/// a swapgs of its own. Any scheme where kernel GS depends on how the thread
/// got there breaks the moment the scheduler runs.
pub fn init() void {
    writeMsr(IA32_GS_BASE, @intFromPtr(&cpu0));
    writeMsr(IA32_KERNEL_GS_BASE, 0);
}

pub fn self() *PerCpu {
    return &cpu0;
}

pub fn setKernelStack(rsp: u64) void {
    cpu0.kernel_rsp = rsp;
}
