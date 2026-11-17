//! Per-processor data on Arm64, reached through TPIDR_EL1.
//!
//! The same block the x86 kernel keeps behind GS. TPIDR_EL1 is a register
//! only the kernel can touch, set once for each processor to the address of
//! its own block.

const cpu = @import("cpu.zig");

pub const PerCpu = extern struct {
    /// Top of the running task's kernel stack. On Arm the processor does not
    /// read this itself (it keeps using the stack pointer it had when it
    /// last left kernel level); user.zig uses it for a task's first entry.
    kernel_rsp: u64 = 0,
    user_rsp: u64 = 0,
    current_task: u64 = 0,
    cpu_index: u64 = 0,
    /// The processor's hardware number (MPIDR affinity).
    apic_id: u64 = 0,

    // ── Scheduler state, per processor (see the x86 file for the story) ──
    current: ?*anyopaque = null,
    idle: ?*anyopaque = null,
    need_resched: bool = false,
    preempt_depth: u32 = 0,
    switches: u64 = 0,
    idle_ticks: u64 = 0,
    busy_ticks: u64 = 0,
};

pub const MAX_CPUS = 32;

var blocks: [MAX_CPUS]PerCpu = [_]PerCpu{.{}} ** MAX_CPUS;

pub fn init() void {
    initAp(0, @truncate(cpu.affinity()));
}

pub fn initAp(index: usize, hardware_number: u32) void {
    blocks[index].cpu_index = index;
    blocks[index].apic_id = hardware_number;
    cpu.write("tpidr_el1", @intFromPtr(&blocks[index]));
    // Programs may read (not write) this register: their cheap way to ask
    // which processor they are on, as x86 programs use CPUID.
    cpu.write("tpidrro_el0", index);
}

pub fn blockAddr(index: usize) u64 {
    return @intFromPtr(&blocks[index]);
}

pub fn block(index: usize) *PerCpu {
    return &blocks[index];
}

/// This processor's own block. Only meaningful while this thread cannot
/// migrate: with interrupts masked or inside a preempt.Guard.
pub inline fn this() *PerCpu {
    return @ptrFromInt(cpu.read("tpidr_el1"));
}

pub fn self() *PerCpu {
    return this();
}

/// Which processor is executing this code.
pub inline fn cpuIndex() usize {
    return @intCast(this().cpu_index);
}

/// The task running on this processor. x86 reads it in one instruction
/// that cannot be split. Arm needs two (find the block, then read it), and
/// a thread moved to another processor between them would read the old
/// processor's task, so interrupts are held off across the pair.
pub inline fn currentTask() ?*anyopaque {
    const daif = cpu.read("daif");
    asm volatile ("msr daifset, #2");
    const task = this().current;
    cpu.write("daif", daif);
    return task;
}

pub fn setKernelStack(top: u64) void {
    this().kernel_rsp = top;
}
