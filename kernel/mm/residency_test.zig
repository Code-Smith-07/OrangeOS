//! Runtime-only kernel workers sharing a user PML4. This is not a user thread
//! ABI: frames stay allocated for the whole probe and only one writer edits
//! the already-created leaf PTE. Workers exercise migration and simultaneous
//! shootdown senders without permitting unmap/user-copy races.
const std = @import("std");
const spaces = @import("address_space.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const sched = @import("../sched/sched.zig");
const preempt = @import("../sched/preempt.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const spinlock = @import("../sync/spinlock.zig");
const tsc = @import("../time/tsc.zig");
const console = @import("../console.zig");
const smp = @import("../arch/x86_64/smp.zig");

const VA: u64 = 0x0000_3000_0000_0000;
const WORKERS = 8;
const ROUNDS = 64;
const A: u64 = 0x7350_aaaa_7350_aaaa;
const B: u64 = 0x7350_bbbb_7350_bbbb;

pub fn testPreemptGuard() void {
    var ok = true;
    {
        const outer = preempt.acquire();
        defer outer.release();
        const task = sched.currentTask().?;
        const local = percpu.this();
        const start_cpu = percpu.cpuIndex();
        const switches = task.switches;
        const ticks: *const volatile u64 = &task.ticks_used;
        const tick_before = ticks.*;
        const inner = preempt.acquire();
        ok = ok and local.preempt_depth == 2 and spinlock.interruptsEnabled();
        inner.release();
        ok = ok and local.preempt_depth == 1;
        const pending: *const volatile bool = &local.need_resched;
        const deadline = tsc.microsSinceBoot() + 1_000_000;
        while ((!pending.* or ticks.* == tick_before) and tsc.microsSinceBoot() < deadline) {
            asm volatile ("pause");
        }
        ok = ok and pending.* and ticks.* > tick_before and
            percpu.cpuIndex() == start_cpu and task.switches == switches and
            spinlock.interruptsEnabled();
    }
    ok = ok and percpu.this().preempt_depth == 0;
    console.print("[{s}] preemption guard: nested pinning keeps timer interrupts live\n", .{if (ok) "pass" else "FAIL"});
}

const Shared = struct {
    space: *spaces.AddressSpace,
    phase: u64 = 0,
    stop: bool = false,
    failed: bool = false,
    observed_cpus: u64 = 0,
    worker_cpus: [WORKERS]u64 = [_]u64{0} ** WORKERS,
    contend: bool = false,
    contenders_ready: usize = 0,
    contention_done: usize = 0,
    seen: [WORKERS]u64 = [_]u64{std.math.maxInt(u64)} ** WORKERS,
};
const Worker = struct { shared: *Shared, index: usize };

fn pinnedReader(arg: ?*anyopaque) void {
    const shared: *Shared = @ptrCast(@alignCast(arg.?));
    sched.attachCurrentUserSpace(shared.space);
    const pin = preempt.acquire();
    defer pin.release();
    const task = sched.currentTask().?;
    const switches = task.switches;
    const value: *const volatile u64 = @ptrFromInt(VA);
    var last: u64 = std.math.maxInt(u64);
    while (!@atomicLoad(bool, &shared.stop, .acquire)) {
        const phase = @atomicLoad(u64, &shared.phase, .acquire);
        if (phase & 1 == 0 and phase != last) {
            // Stay on this CR3 across EVERY remap, accepting IPIs but never
            // yielding. A context-switch TLB flush cannot mask a missing IPI.
            const got = value.*;
            const expected = if ((phase / 2) & 1 == 0) A else B;
            if (got != expected or task.switches != switches or !spinlock.interruptsEnabled())
                @atomicStore(bool, &shared.failed, true, .release);
            last = phase;
            @atomicStore(u64, &shared.seen[0], phase, .release);
        }
        asm volatile ("pause");
    }
}

fn waitForPinnedReader(shared: *Shared, phase: u64) !void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (@atomicLoad(u64, &shared.seen[0], .acquire) != phase) {
        if (tsc.microsSinceBoot() >= deadline) return error.PinnedReaderTimedOut;
        sched.sleepMs(1);
    }
    if (@atomicLoad(bool, &shared.failed, .acquire)) return error.PinnedReaderStaleMapping;
}

fn pinnedProbe(space: *spaces.AddressSpace, a: u64, b: u64) !void {
    var shared = Shared{ .space = space };
    space.retain();
    const child = sched.spawn("pinned-resident", pinnedReader, &shared, .normal) catch |err| {
        space.release();
        return err;
    };
    defer {
        @atomicStore(bool, &shared.stop, true, .release);
        join(child);
    }
    try waitForPinnedReader(&shared, 0);
    for (1..ROUNDS + 1) |round| {
        @atomicStore(u64, &shared.phase, round * 2 - 1, .release);
        try vmm.mapPage(space.pml4, VA, if (round & 1 == 0) a else b, vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE);
        const result = space.invalidate(VA);
        if (@popCount(result.remote_mask) != 1) return error.PinnedReaderNotTargeted;
        @atomicStore(u64, &shared.phase, round * 2, .release);
        try waitForPinnedReader(&shared, round * 2);
    }
    console.write("[pass] pinned residency: 64 remaps without a reader CR3 reload\n");
}

fn worker(arg: ?*anyopaque) void {
    const context: *Worker = @ptrCast(@alignCast(arg.?));
    const shared = context.shared;
    // The spawner retained this reference before making us runnable.
    sched.attachCurrentUserSpace(shared.space);
    const value: *const volatile u64 = @ptrFromInt(VA);
    var last: u64 = std.math.maxInt(u64);
    var contended = false;
    while (!@atomicLoad(bool, &shared.stop, .acquire)) {
        if (@atomicLoad(bool, &shared.contend, .acquire) and !contended) {
            // Separate from the remap/readback stage: an extra invalidation by
            // a reader must not hide a broken coordinator shootdown.
            const pin = preempt.acquire();
            _ = @atomicRmw(usize, &shared.contenders_ready, .Add, 1, .acq_rel);
            const deadline = tsc.microsSinceBoot() + 5_000_000;
            // Hold residency until at least two CPUs have real senders. Merely
            // spawning eight tasks may execute every request serially on TCG.
            while (@atomicLoad(usize, &shared.contenders_ready, .acquire) < @min(smp.cpusOnline(), 2)) {
                if (tsc.microsSinceBoot() >= deadline) @panic("TLB contender rendezvous timeout");
                asm volatile ("pause");
            }
            for (0..64) |_| _ = shared.space.invalidate(VA);
            pin.release();
            contended = true;
            _ = @atomicRmw(usize, &shared.contention_done, .Add, 1, .release);
        }
        {
            const pin = preempt.acquire();
            defer pin.release();
            const bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
            _ = @atomicRmw(u64, &shared.observed_cpus, .Or, bit, .monotonic);
            _ = @atomicRmw(u64, &shared.worker_cpus[context.index], .Or, bit, .monotonic);
            if (shared.space.residentCpus() & bit == 0 or vmm.currentCr3() != shared.space.pml4)
                @atomicStore(bool, &shared.failed, true, .release);
            const before = @atomicLoad(u64, &shared.phase, .acquire);
            if (before & 1 == 0 and before != last) {
                const got = value.*;
                asm volatile ("" ::: "memory");
                const after = @atomicLoad(u64, &shared.phase, .acquire);
                if (before == after) {
                    const expected = if ((before / 2) & 1 == 0) A else B;
                    if (got != expected) @atomicStore(bool, &shared.failed, true, .release);
                    last = before;
                    @atomicStore(u64, &shared.seen[context.index], before, .release);
                }
            }
        }
        sched.yield();
    }
    // Normal task exit releases our space reference and clears CPU residency.
}

fn waitForReaders(shared: *Shared, phase: u64) !void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (true) {
        var ready = true;
        for (&shared.seen) |*seen| {
            if (@atomicLoad(u64, seen, .acquire) != phase) ready = false;
        }
        if (@atomicLoad(bool, &shared.failed, .acquire)) return error.StaleMapping;
        if (ready) return;
        if (tsc.microsSinceBoot() >= deadline) return error.ReadersTimedOut;
        sched.sleepMs(1);
    }
}

fn join(task: *sched.Task) void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (sched.taskExitCode(task) == null) {
        if (tsc.microsSinceBoot() >= deadline) @panic("residency probe worker did not exit");
        sched.sleepMs(1);
    }
    std.debug.assert(sched.reapChild(task, sched.currentTask().?.tid).? == 0);
}

pub fn run() !void {
    // Free borrowed frames only after the final page-table reference is gone.
    const a = try pmm.allocPage();
    defer pmm.freePage(a);
    const b = try pmm.allocPage();
    defer pmm.freePage(b);
    @as(*u64, @ptrFromInt(pmm.physToVirt(a))).* = A;
    @as(*u64, @ptrFromInt(pmm.physToVirt(b))).* = B;
    const space = try spaces.AddressSpace.create();
    defer space.release();
    const flags = vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE;
    try vmm.mapPage(space.pml4, VA, a, flags);
    if (smp.cpusOnline() > 1) try pinnedProbe(space, a, b);
    var shared = Shared{ .space = space };
    var contexts: [WORKERS]Worker = undefined;
    var children: [WORKERS]*sched.Task = undefined;
    var count: usize = 0;
    defer {
        @atomicStore(bool, &shared.stop, true, .release);
        for (children[0..count]) |child| join(child);
    }
    for (&contexts, 0..) |*context, i| {
        context.* = .{ .shared = &shared, .index = i };
        space.retain();
        children[i] = sched.spawn("resident-probe", worker, context, .normal) catch |err| {
            space.release();
            return err;
        };
        count += 1;
    }
    try waitForReaders(&shared, 0);
    for (1..ROUNDS + 1) |round| {
        @atomicStore(u64, &shared.phase, round * 2 - 1, .release);
        try vmm.mapPage(space.pml4, VA, if (round & 1 == 0) a else b, flags);
        _ = space.invalidate(VA);
        @atomicStore(u64, &shared.phase, round * 2, .release);
        try waitForReaders(&shared, round * 2);
    }
    const contention_before = @import("tlb.zig").contentionCount();
    @atomicStore(bool, &shared.contend, true, .release);
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (@atomicLoad(usize, &shared.contention_done, .acquire) != WORKERS) {
        if (tsc.microsSinceBoot() >= deadline) return error.ContendersTimedOut;
        sched.sleepMs(1);
    }
    const contentions = @import("tlb.zig").contentionCount() - contention_before;
    @atomicStore(bool, &shared.stop, true, .release);
    for (children[0..count]) |child| join(child);
    count = 0;
    const observed = @atomicLoad(u64, &shared.observed_cpus, .acquire);
    if (@popCount(observed) < @min(smp.cpusOnline(), 2)) return error.NoCpuCoverage;
    var migrated = false;
    for (&shared.worker_cpus) |*mask| {
        if (@popCount(@atomicLoad(u64, mask, .acquire)) > 1) migrated = true;
    }
    if (smp.cpusOnline() > 1 and contentions == 0) return error.NoContention;
    if (space.residentCpus() != 0) return error.ResidencyLeak;
    console.print("[pass] address-space residency: 8 workers, 64 remaps, CPU mask {x}, zero residents after exit\n", .{observed});
    console.print("[pass] TLB contention: 512 worker requests, {d} lock contentions with interrupts enabled\n", .{contentions});
    console.print("[info] residency worker migration observed: {}\n", .{migrated});
}
