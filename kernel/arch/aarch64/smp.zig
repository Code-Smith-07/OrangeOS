//! The other processors on Arm64: starting them (PSCI), knowing which are
//! running, and interrupting them (GIC software interrupts).

const std = @import("std");
const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const apic = @import("apic.zig");
const isr = @import("isr.zig");
const mmu = @import("mmu.zig");
const percpu = @import("percpu.zig");
const bootinfo = @import("bootinfo.zig");
const tsc = @import("tsc.zig");
const console = @import("../../console.zig");
const sched = @import("../../sched/sched.zig");
const time = @import("../../time/time.zig");
const vmm = @import("../../mm/vmm.zig");

/// Interrupts one processor sends another (GIC numbers 0 to 15).
pub const VECTOR_TLB: u8 = 1;
pub const VECTOR_PANIC_HALT: u8 = 2;

/// In boot.S's section, which is linked at its physical address.
extern const _secondary_start: u8;

var online: usize = 1; // the boot processor
var online_mask: u64 = 1;
var reported: usize = 0;
var release_aps: bool = false;
/// Hardware number of each processor, by index. Index 0 booted.
var ids: [cpu.MAX_CPUS]u64 = [_]u64{0} ** cpu.MAX_CPUS;
var known: usize = 1;

pub fn cpusOnline() usize {
    return @atomicLoad(usize, &online, .acquire);
}

pub fn onlineMask() u64 {
    return @atomicLoad(u64, &online_mask, .acquire);
}

pub fn sendFixedToCpu(index: usize, vector: u8) void {
    gic.sendToProcessor(ids[index], @intCast(vector));
}

fn panicHaltHandler(_: *isr.TrapFrame) void {
    cpu.interruptsOff();
    while (true) cpu.waitForInterrupt();
}

pub fn installPanicHalt() void {
    isr.register(VECTOR_PANIC_HALT, panicHaltHandler);
}

pub fn haltOtherCpus() void {
    if (cpusOnline() <= 1) return;
    const me = percpu.cpuIndex();
    const mask = onlineMask();
    for (0..known) |i| {
        if (i != me and mask & (@as(u64, 1) << @intCast(i)) != 0) sendFixedToCpu(i, VECTOR_PANIC_HALT);
    }
    tsc.busyWaitUs(50_000);
}

pub fn releaseAps() void {
    @atomicStore(bool, &release_aps, true, .release);
}

/// Start every other processor the device tree lists. Each one runs
/// boot.S, then apEntry below, and waits there until releaseAps().
pub fn init() !void {
    cpu.conduit = if (bootinfo.psci_uses_smc) .smc else .hvc;
    ids[0] = cpu.affinity();
    for (bootinfo.cpu_ids[0..bootinfo.cpu_count]) |id| {
        if (id == ids[0] or known >= cpu.MAX_CPUS) continue;
        const index = known;
        ids[index] = id;
        known += 1;
        const before = @atomicLoad(usize, &reported, .acquire);
        const result = cpu.startProcessor(id, @intFromPtr(&_secondary_start), index);
        if (result != 0) {
            console.warn("processor 0x{x} refused to start ({d})", .{ id, result });
            continue;
        }
        // One at a time: each must report before the next is started.
        const deadline = tsc.microsSinceBoot() + 2_000_000;
        while (@atomicLoad(usize, &reported, .acquire) == before and tsc.microsSinceBoot() < deadline) cpu.relax();
        if (@atomicLoad(usize, &reported, .acquire) == before) console.warn("processor 0x{x} did not report in 2 s", .{id});
    }
    console.print("[ ok ] SMP: {d} of {d} processors online\n", .{ cpusOnline(), bootinfo.cpu_count });
}

/// A started processor arrives here from boot.S (through kmain), on its
/// boot stack, with boot.S's page tables.
pub fn apEntry(index: usize) noreturn {
    // The kernel's real tables first: the heap and every thread stack are
    // only mapped there.
    mmu.installKernelRoot(vmm.kernelPml4());
    percpu.initAp(index, @truncate(cpu.affinity()));
    isr.install();
    if (!gic.initProcessor()) {
        _ = @atomicRmw(usize, &reported, .Add, 1, .seq_cst);
        while (true) cpu.waitForInterrupt();
    }
    sched.initCpu(index) catch {
        _ = @atomicRmw(usize, &reported, .Add, 1, .seq_cst);
        while (true) cpu.waitForInterrupt();
    };
    _ = @atomicRmw(u64, &online_mask, .Or, @as(u64, 1) << @intCast(index), .acq_rel);
    _ = @atomicRmw(usize, &online, .Add, 1, .seq_cst);
    _ = @atomicRmw(usize, &reported, .Add, 1, .seq_cst);

    while (!@atomicLoad(bool, &release_aps, .acquire)) cpu.relax();

    apic.startTimer(time.TICK_HZ);
    cpu.interruptsOn();
    sched.startAp();
}
