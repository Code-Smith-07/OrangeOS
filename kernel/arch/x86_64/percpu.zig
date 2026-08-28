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
    /// gs:24 — this CPU's index into the block array. Read through GS so a
    /// core can identify itself without a lock or a lookup.
    cpu_index: u64 = 0,
    /// gs:32 — this CPU's LAPIC id.
    apic_id: u64 = 0,

    // ── Scheduler state, per CPU ────────────────────────────────────────────
    // `current` used to be a single global. With more than one core running
    // the scheduler that is immediately wrong: two CPUs would believe they
    // were running the same task and both would switch away from it.
    current: ?*anyopaque = null,
    idle: ?*anyopaque = null,
    /// Set by the timer tick, acted on where switching is safe.
    need_resched: bool = false,
    switches: u64 = 0,
    /// Timer ticks sampled with this core's idle task running, and with
    /// anything else running. The ratio is what 16.2 budgets as "idle CPU".
    /// Sampled rather than accumulated: a counter incremented in the timer
    /// interrupt cannot be fooled by a context switch landing mid-measurement.
    idle_ticks: u64 = 0,
    busy_ticks: u64 = 0,
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
    blocks[0].cpu_index = 0;
    blocks[0].apic_id = 0;
    writeMsr(IA32_GS_BASE, @intFromPtr(&blocks[0]));
    writeMsr(IA32_KERNEL_GS_BASE, 0);
}

/// Establish the same invariant on an application processor. Called from the
/// AP's own entry point, on its own stack.
pub fn initAp(index: usize, apic_id_value: u32) void {
    blocks[index].cpu_index = index;
    blocks[index].apic_id = apic_id_value;
    writeMsr(IA32_GS_BASE, @intFromPtr(&blocks[index]));
    writeMsr(IA32_KERNEL_GS_BASE, 0);
}

fn readMsrRaw(msr: u32) u64 {
    // One rdmsr, both halves out of the same instruction. Issuing two separate
    // rdmsr instructions and taking eax from one and edx from the other is not
    // a 64-bit read: the compiler is free to schedule them independently, and
    // the halves can come from different executions.
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

pub fn gsBase() u64 {
    return readMsrRaw(IA32_GS_BASE);
}

pub fn blockAddr(index: usize) u64 {
    return @intFromPtr(&blocks[index]);
}

pub fn block(index: usize) *PerCpu {
    return &blocks[index];
}

/// Which core is executing this code. Read straight out of GS, so it is
/// correct on every core with no lock and no lookup.
pub inline fn cpuIndex() usize {
    return @intCast(asm volatile ("movq %%gs:24, %[out]"
        : [out] "=r" (-> u64),
    ));
}

/// This CPU's own block.
pub inline fn this() *PerCpu {
    return &blocks[cpuIndex()];
}

pub fn self() *PerCpu {
    return this();
}

pub fn setKernelStack(rsp: u64) void {
    this().kernel_rsp = rsp;
}
