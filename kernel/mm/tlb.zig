//! Synchronous cross-CPU invalidation for a single virtual page.
//!
//! The request is serialized and acknowledged before the caller can free or
//! reuse a frame. The IPI handler takes no locks, so a target interrupted
//! while holding another spinlock can still acknowledge. This is the hardware
//! mechanism; shared user address spaces still need VM mutation ownership.
const std = @import("std");
const spinlock = @import("../sync/spinlock.zig");
const isr = @import("../arch/x86_64/isr.zig");
const apic = @import("../arch/x86_64/apic.zig");
const smp = @import("../arch/x86_64/smp.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const tsc = @import("../time/tsc.zig");
const vmm = @import("vmm.zig");

pub const VECTOR: u8 = 0xF1;
pub const Result = struct {
    remote_mask: u64,
    samples: [percpu.MAX_CPUS]u64,
};

var request_lock: spinlock.SpinLock = .{};
var ready: bool = false;
var generation: u64 = 0;
var next_generation: u64 = 0; // sender only, protected by request_lock
var target_cr3: u64 = 0; // 0 means every address space (kernel mapping)
var target_page: u64 = 0;
var sample_page: bool = false;
var target_mask: u64 = 0;
var pending: usize = 0;
var remote_mask: u64 = 0;
var last_generation: [percpu.MAX_CPUS]u64 = [_]u64{0} ** percpu.MAX_CPUS;
var samples: [percpu.MAX_CPUS]u64 = [_]u64{0} ** percpu.MAX_CPUS;
var deliveries: [percpu.MAX_CPUS]u64 = [_]u64{0} ** percpu.MAX_CPUS;

pub fn init() void {
    isr.register(VECTOR, handler);
}

/// Called after the APs have been released into the scheduler.
pub fn enable() void {
    @atomicStore(bool, &ready, true, .release);
}

fn handler(_: *isr.TrapFrame) void {
    const epoch = @atomicLoad(u64, &generation, .acquire);
    const cpu = percpu.cpuIndex();
    _ = @atomicRmw(u64, &deliveries[cpu], .Add, 1, .monotonic);
    if (epoch != 0 and target_mask & (@as(u64, 1) << @intCast(cpu)) != 0 and
        last_generation[cpu] != epoch)
    {
        last_generation[cpu] = epoch;
        if (target_cr3 == 0 or vmm.currentCr3() == target_cr3) {
            vmm.invalidatePage(target_page);
            if (sample_page) {
                const value: *const volatile u64 = @ptrFromInt(target_page);
                samples[cpu] = value.*;
            }
        }
        _ = @atomicRmw(u64, &remote_mask, .Or, @as(u64, 1) << @intCast(cpu), .acq_rel);
        _ = @atomicRmw(usize, &pending, .Sub, 1, .acq_rel);
    }
    apic.eoi();
}

fn request(cr3: u64, address: u64, sample: bool, requested_mask: u64) Result {
    std.debug.assert(address % vmm.PAGE_SIZE == 0);
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    std.debug.assert(requested_mask & self_bit == 0);
    const targets = if (@atomicLoad(bool, &ready, .acquire)) requested_mask else 0;
    std.debug.assert(targets & ~smp.onlineMask() == 0);
    // A contender must keep accepting the other sender's IPI while waiting
    // for this lock. Acquiring it with IRQs masked deadlocks two requesters.
    if (targets != 0 and
        !spinlock.interruptsEnabled()) @panic("remote TLB shootdown requires interrupts enabled");
    request_lock.acquire();
    defer request_lock.release();

    if (cr3 == 0 or vmm.currentCr3() == cr3) vmm.invalidatePage(address);
    samples = [_]u64{0} ** percpu.MAX_CPUS;
    if (targets == 0) return .{ .remote_mask = 0, .samples = samples };

    target_cr3 = cr3;
    target_page = address;
    sample_page = sample;
    target_mask = targets;
    @atomicStore(u64, &remote_mask, 0, .release);
    @atomicStore(usize, &pending, @popCount(targets), .release);
    next_generation +%= 1;
    if (next_generation == 0) next_generation = 1;
    @atomicStore(u64, &generation, next_generation, .release);
    for (0..percpu.MAX_CPUS) |cpu| {
        if (targets & (@as(u64, 1) << @intCast(cpu)) != 0)
            smp.sendFixedToCpu(cpu, VECTOR);
    }

    const deadline = tsc.microsSinceBoot() + 1_000_000;
    while (@atomicLoad(usize, &pending, .acquire) != 0) {
        if (tsc.microsSinceBoot() >= deadline) @panic("TLB shootdown timeout");
        asm volatile ("pause");
    }
    return .{ .remote_mask = @atomicLoad(u64, &remote_mask, .acquire), .samples = samples };
}

/// Invalidate `address` on this CPU and every CPU currently executing `cr3`.
/// Pass cr3=0 for a kernel mapping shared by all address spaces.
pub fn invalidate(cr3: u64, address: u64) void {
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    _ = request(cr3, address, false, smp.onlineMask() & ~self_bit);
}

/// Current user processes have exactly one task per address space. They need
/// local invalidation before recycling frames, but broadcasting from their
/// IRQ-masked syscall/exit paths would deadlock against another masked CPU.
/// Do not use this once an address space can be scheduled by multiple tasks.
pub fn invalidateExclusiveRange(cr3: u64, address: u64, pages: usize) void {
    std.debug.assert(address % vmm.PAGE_SIZE == 0);
    if (vmm.currentCr3() != cr3) return;
    for (0..pages) |i| vmm.invalidatePage(address + i * vmm.PAGE_SIZE);
}

/// Test-only readback after remote invalidation, for a mapped kernel page.
pub fn sampleKernelPage(address: u64) Result {
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    return request(0, address, true, smp.onlineMask() & ~self_bit);
}

/// Probe one selected remote CPU; the returned mask contains acknowledgements.
pub fn sampleKernelCpu(address: u64, cpu: usize) Result {
    std.debug.assert(cpu < percpu.MAX_CPUS);
    return request(0, address, true, @as(u64, 1) << @intCast(cpu));
}

/// Raw fixed-vector delivery count, used to prove an excluded CPU was not sent
/// an IPI (rather than merely that it did not acknowledge one).
pub fn deliveryCount(cpu: usize) u64 {
    std.debug.assert(cpu < percpu.MAX_CPUS);
    return @atomicLoad(u64, &deliveries[cpu], .acquire);
}
