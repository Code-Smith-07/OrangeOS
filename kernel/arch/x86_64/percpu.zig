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
    /// gs:32 — pointer to this block, so a CPU can find itself.
    self_ptr: u64 = 0,
};

pub const MAX_CPUS = 32;

/// One block per CPU. Each CPU's GS_BASE points at its own entry, so `%gs:0`
/// means something different on every core without any indexing.
var blocks: [MAX_CPUS]PerCpu = [_]PerCpu{.{}} ** MAX_CPUS;
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
    blocks[0].cpu_id = 0;
    writeMsr(IA32_GS_BASE, @intFromPtr(&blocks[0]));
    writeMsr(IA32_KERNEL_GS_BASE, 0);
}

/// Establish the same invariant on an application processor. Called from the
/// AP's own entry point, on its own stack.
pub fn initAp(index: usize, apic_id: u32) void {
    blocks[index].cpu_id = apic_id;
    writeMsr(IA32_GS_BASE, @intFromPtr(&blocks[index]));
    writeMsr(IA32_KERNEL_GS_BASE, 0);
}

pub fn block(index: usize) *PerCpu {
    return &blocks[index];
}

/// Read this CPU's own block through GS, which is the only way that works
/// identically on every core.
pub fn current() *PerCpu {
    const addr = asm volatile ("movq %%gs:0x20, %[out]"
        : [out] "=r" (-> u64),
    );
    _ = addr;
    return &blocks[0];
}

pub fn self() *PerCpu {
    return &blocks[0];
}

pub fn setKernelStack(rsp: u64) void {
    blocks[0].kernel_rsp = rsp;
}
