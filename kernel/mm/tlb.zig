//! Synchronous cross-CPU invalidation of a page range.
//!
//! The request is serialized and acknowledged before the caller can free or
//! reuse a frame. The IPI handler takes no locks, so a target interrupted
//! while holding another spinlock can still acknowledge. Long ranges become a
//! full non-global flush on each target instead of one INVLPG per page.
const std = @import("std");
const spinlock = @import("../sync/spinlock.zig");
const isr = @import("../arch/x86_64/isr.zig");
const apic = @import("../arch/x86_64/apic.zig");
const smp = @import("../arch/x86_64/smp.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const tsc = @import("../time/tsc.zig");
const vmm = @import("vmm.zig");
const preempt = @import("../sched/preempt.zig");

pub const VECTOR: u8 = 0xF1;
/// Above this many pages a CR3 reload is cheaper than per-page INVLPG.
pub const FULL_FLUSH_PAGES: usize = 32;
pub const Result = struct {
    remote_mask: u64,
    samples: [percpu.MAX_CPUS]u64,
};

var request_lock: spinlock.SpinLock = .{};
var contentions: u64 = 0;
var ready: bool = false;
var generation: u64 = 0;
var next_generation: u64 = 0; // sender only, protected by request_lock
var target_cr3: u64 = 0; // 0 means every address space (kernel mapping)
var target_page: u64 = 0;
var target_pages: usize = 1;
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

/// Called immediately before releasing APs into the scheduler, so no runnable
/// requester can observe disabled shootdowns on an otherwise live SMP system.
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
            invalidateLocal(target_page, target_pages);
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

/// Invalidate a range on this CPU only.
fn invalidateLocal(address: u64, pages: usize) void {
    if (pages > FULL_FLUSH_PAGES) {
        vmm.flushLocal();
        return;
    }
    for (0..pages) |i| vmm.invalidatePage(address + i * vmm.PAGE_SIZE);
}

fn request(cr3: u64, address: u64, pages: usize, sample: bool, requested_mask: u64) Result {
    const pin = preempt.acquire();
    defer pin.release();
    std.debug.assert(address % vmm.PAGE_SIZE == 0 and pages != 0);
    // A CR3 reload keeps global (kernel) translations, so kernel ranges must
    // stay on the per-page path.
    std.debug.assert(cr3 != 0 or pages <= FULL_FLUSH_PAGES);
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    std.debug.assert(requested_mask & self_bit == 0);
    const targets = if (@atomicLoad(bool, &ready, .acquire)) requested_mask else 0;
    std.debug.assert(targets & ~smp.onlineMask() == 0);
    const local = cr3 == 0 or vmm.currentCr3() == cr3;
    // Purely local work takes no shared lock. An exit path with IRQs masked
    // must never spin behind a sender that is waiting for this CPU's ack.
    if (targets == 0) {
        if (local) invalidateLocal(address, pages);
        return .{ .remote_mask = 0, .samples = [_]u64{0} ** percpu.MAX_CPUS };
    }
    // A contender must keep accepting the other sender's IPI while waiting
    // for this lock. Acquiring it with IRQs masked deadlocks two requesters.
    if (!spinlock.interruptsEnabled()) @panic("remote TLB shootdown requires interrupts enabled");
    if (!request_lock.tryAcquire()) {
        _ = @atomicRmw(u64, &contentions, .Add, 1, .monotonic);
        request_lock.acquire();
    }
    defer request_lock.release();

    if (local) invalidateLocal(address, pages);
    samples = [_]u64{0} ** percpu.MAX_CPUS;

    target_cr3 = cr3;
    target_page = address;
    target_pages = pages;
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
    const pin = preempt.acquire();
    defer pin.release();
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    _ = request(cr3, address, 1, false, smp.onlineMask() & ~self_bit);
}

/// Snapshot-based targeted invalidation. Caller must remain CPU-pinned from
/// selection of requested_mask through this call (and exclude its own CPU).
pub fn invalidateMask(cr3: u64, address: u64, requested_mask: u64) Result {
    std.debug.assert(percpu.this().preempt_depth != 0);
    return request(cr3, address, 1, false, requested_mask);
}

/// Range form of invalidateMask, for one user address space. The caller stays
/// pinned from choosing `requested_mask` through this call; remote targets
/// require interrupts enabled.
pub fn invalidateRangeMask(cr3: u64, address: u64, pages: usize, requested_mask: u64) Result {
    std.debug.assert(percpu.this().preempt_depth != 0 and cr3 != 0);
    return request(cr3, address, pages, false, requested_mask);
}

/// Test-only readback after remote invalidation, for a mapped kernel page.
pub fn sampleKernelPage(address: u64) Result {
    const pin = preempt.acquire();
    defer pin.release();
    const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    return request(0, address, 1, true, smp.onlineMask() & ~self_bit);
}

/// Probe one selected remote CPU; the returned mask contains acknowledgements.
pub fn sampleKernelCpu(address: u64, cpu: usize) Result {
    std.debug.assert(cpu < percpu.MAX_CPUS);
    return request(0, address, 1, true, @as(u64, 1) << @intCast(cpu));
}

/// Raw fixed-vector delivery count, used to prove an excluded CPU was not sent
/// an IPI (rather than merely that it did not acknowledge one).
pub fn deliveryCount(cpu: usize) u64 {
    std.debug.assert(cpu < percpu.MAX_CPUS);
    return @atomicLoad(u64, &deliveries[cpu], .acquire);
}

pub fn contentionCount() u64 {
    return @atomicLoad(u64, &contentions, .acquire);
}
