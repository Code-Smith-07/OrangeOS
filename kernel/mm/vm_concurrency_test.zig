//! Runtime-only probes of concurrent user VM changes (-Druntime-test).
//!
//! Kernel workers attach to one user address space the way threads of one
//! program will, while a coordinator changes its anonymous mappings through
//! the same functions the VM syscalls call. Frames released by each change are
//! immediately re-allocated as poisoned decoys, so a missing shootdown or a
//! copy that outlives its frame reads (or overwrites) poison instead of
//! passing by accident.
const std = @import("std");
const spaces = @import("address_space.zig");
const user_vm = @import("user_vm.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const validate = @import("../syscall/validate.zig");
const sched = @import("../sched/sched.zig");
const preempt = @import("../sched/preempt.zig");
const smp = @import("../arch/x86_64/smp.zig");
const tsc = @import("../time/tsc.zig");
const console = @import("../console.zig");

const PAGE = vmm.PAGE_SIZE;
const POISON: u64 = 0xdead_f00d_dead_f00d;
const ROUNDS = 64;
const COPY_ROUNDS = 192;
const COPY_PAGES = 2;
const MAX_PAGES = 48;

fn pattern(generation: u64) u64 {
    return 0x5eed_0000_0000_0000 | generation;
}

fn fill(phys: u64, value: u64) void {
    const words: [*]u64 = @ptrFromInt(pmm.physToVirt(phys));
    for (words[0 .. PAGE / 8]) |*word| word.* = value;
}

fn fillRange(space: *spaces.AddressSpace, address: u64, pages: usize, value: u64) void {
    for (0..pages) |i| fill(vmm.translate(space.pml4, address + i * PAGE).?, value);
}

/// Frames a change just released, taken back from the allocator and poisoned.
const Decoys = struct {
    frames: [MAX_PAGES]u64 = undefined,
    count: usize = 0,

    /// Grab `pages` frames; count how many are ones `released` just held.
    fn grab(self: *Decoys, pages: usize, released: []const u64) usize {
        var captured: usize = 0;
        self.count = 0;
        while (self.count < pages) : (self.count += 1) {
            const phys = pmm.allocPage() catch break;
            fill(phys, POISON);
            self.frames[self.count] = phys;
            if (std.mem.indexOfScalar(u64, released, phys) != null) captured += 1;
        }
        return captured;
    }

    /// Free them. False if anything overwrote the poison meanwhile.
    fn release(self: *Decoys) bool {
        var intact = true;
        for (self.frames[0..self.count]) |phys| {
            const words: [*]const u64 = @ptrFromInt(pmm.physToVirt(phys));
            for (words[0 .. PAGE / 8]) |word| {
                if (word != POISON) intact = false;
            }
            pmm.freePage(phys);
        }
        self.count = 0;
        return intact;
    }
};

fn framesOf(space: *spaces.AddressSpace, address: u64, pages: usize, out: []u64) []u64 {
    for (0..pages) |i| out[i] = vmm.translate(space.pml4, address + i * PAGE).?;
    return out[0..pages];
}

fn join(task: *sched.Task) void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (sched.taskExitCode(task) == null) {
        if (tsc.microsSinceBoot() >= deadline) @panic("VM concurrency worker did not exit");
        sched.sleepMs(1);
    }
    std.debug.assert(sched.reapChild(task, sched.currentTask().?.tid).? == 0);
}

// ── Stale translations ──────────────────────────────────────────────────────

const Reader = struct {
    space: *spaces.AddressSpace,
    address: u64 = 0,
    pages: usize = 0,
    /// Odd while the coordinator changes the range; each even value is a
    /// stable generation the reader must see through its own TLB.
    phase: u64 = 0,
    seen: u64 = std.math.maxInt(u64),
    stop: bool = false,
    failed: bool = false,
};

/// Pinned to one CPU with interrupts live, reading the range straight through
/// the hardware TLB and never reloading CR3: only a correct remote shootdown
/// can refresh its translations.
fn pinnedReader(arg: ?*anyopaque) void {
    const reader: *Reader = @ptrCast(@alignCast(arg.?));
    sched.attachCurrentUserSpace(reader.space);
    const pin = preempt.acquire();
    defer pin.release();
    var last: u64 = std.math.maxInt(u64);
    while (!@atomicLoad(bool, &reader.stop, .acquire)) {
        const phase = @atomicLoad(u64, &reader.phase, .acquire);
        if (phase & 1 == 0 and phase != last) {
            const expected = pattern(phase / 2);
            for (0..reader.pages) |i| {
                const word: *const volatile u64 = @ptrFromInt(reader.address + i * PAGE);
                if (word.* != expected) @atomicStore(bool, &reader.failed, true, .release);
            }
            last = phase;
            // Published only after every read, so the coordinator never
            // changes the range while this CPU is still touching it.
            @atomicStore(u64, &reader.seen, phase, .release);
        }
        asm volatile ("pause");
    }
}

fn waitSeen(reader: *Reader, phase: u64) !void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (@atomicLoad(u64, &reader.seen, .acquire) != phase) {
        if (tsc.microsSinceBoot() >= deadline) return error.ReaderTimedOut;
        sched.sleepMs(1);
    }
    if (@atomicLoad(bool, &reader.failed, .acquire)) return error.StaleTranslation;
}

/// Unmap and remap the same range while another CPU holds its translations.
/// `sparse` drives the decommit/commit path of a reservation instead.
fn staleTranslationProbe(pages: usize, sparse: bool) !void {
    const space = try spaces.AddressSpace.create();
    defer space.release();
    const bytes = pages * PAGE;
    var reader = Reader{ .space = space, .pages = pages };
    var decoys: Decoys = .{};
    defer _ = decoys.release();
    if (sparse) {
        reader.address = try user_vm.reserve(space, 4 * bytes);
        try user_vm.commit(space, reader.address, bytes, 3);
    } else {
        reader.address = try user_vm.map(space, bytes, 3);
    }
    fillRange(space, reader.address, pages, pattern(0));

    space.retain();
    const child = sched.spawn("vm-reader", pinnedReader, &reader, .normal) catch |err| {
        space.release();
        return err;
    };
    defer {
        @atomicStore(bool, &reader.stop, true, .release);
        join(child);
    }
    try waitSeen(&reader, 0);

    var remote_rounds: usize = 0;
    var captured: usize = 0;
    for (1..ROUNDS + 1) |round| {
        @atomicStore(u64, &reader.phase, round * 2 - 1, .release);
        if (!decoys.release()) return error.DecoyOverwritten;
        if (space.residentCpus() != 0) remote_rounds += 1;
        var old: [MAX_PAGES]u64 = undefined;
        const released = framesOf(space, reader.address, pages, &old);
        if (sparse) {
            try user_vm.decommit(space, reader.address, bytes);
        } else {
            try user_vm.unmap(space, reader.address, bytes);
        }
        captured += decoys.grab(pages, released);
        if (sparse) {
            try user_vm.commit(space, reader.address, bytes, 3);
        } else if (try user_vm.map(space, bytes, 3) != reader.address) return error.AddressNotReused;
        fillRange(space, reader.address, pages, pattern(round));
        @atomicStore(u64, &reader.phase, round * 2, .release);
        try waitSeen(&reader, round * 2);
    }
    if (remote_rounds != ROUNDS) return error.ReaderNotResident;
    console.print("[pass] concurrent user VM: {d} {s} rounds of {d} pages refresh a pinned remote TLB ({d}/{d} freed frames re-poisoned)\n", .{
        ROUNDS, if (sparse) "decommit/commit" else "unmap/remap", pages, captured, ROUNDS * pages,
    });
}

// ── Deterministic detach: borrowed frames at a fixed address ─────────────
//
// Owned frames go back to the allocator, which rarely returns the very same
// frames next, so a stale access to them is only probabilistically visible.
// These probes map test-owned frames instead and detach them through the same
// user_vm path (without freeing), then poison them as soon as the detach
// returns. After that point no translation or kernel access may reach them:
// a stale read sees poison, and a stale write is caught when the poison is
// checked before the frames are refilled for their next mapping.

const FIXED_VA: u64 = 0x0000_3100_0000_0000;
const FLAGS = vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE;

const FrameSet = struct {
    frames: [MAX_PAGES]u64 = undefined,
    count: usize = 0,

    fn alloc(pages: usize) !FrameSet {
        var set = FrameSet{};
        errdefer set.free();
        while (set.count < pages) : (set.count += 1) set.frames[set.count] = try pmm.allocPage();
        return set;
    }

    fn free(self: *FrameSet) void {
        for (self.frames[0..self.count]) |phys| pmm.freePage(phys);
        self.count = 0;
    }

    fn fillAll(self: *const FrameSet, value: u64) void {
        for (self.frames[0..self.count]) |phys| fill(phys, value);
    }

    fn holds(self: *const FrameSet, value: u64) bool {
        for (self.frames[0..self.count]) |phys| {
            const words: [*]const u64 = @ptrFromInt(pmm.physToVirt(phys));
            for (words[0 .. PAGE / 8]) |word| {
                if (word != value) return false;
            }
        }
        return true;
    }
};

fn mapFixed(space: *spaces.AddressSpace, set: *const FrameSet) !void {
    const guard = space.lockVm();
    defer guard.unlock();
    for (set.frames[0..set.count], 0..) |phys, i| try vmm.mapPage(space.pml4, FIXED_VA + i * PAGE, phys, FLAGS);
}

fn detachFixed(space: *spaces.AddressSpace, pages: usize) void {
    const guard = space.lockVm();
    defer guard.unlock();
    user_vm.detachLocked(space, FIXED_VA, pages * PAGE, false);
}

/// Alternate two borrowed frame sets under a pinned remote reader.
fn deterministicTlbProbe(pages: usize) !void {
    const space = try spaces.AddressSpace.create();
    defer space.release();
    var sets = [2]FrameSet{ try FrameSet.alloc(pages), .{} };
    defer for (&sets) |*set| set.free();
    sets[1] = try FrameSet.alloc(pages);
    sets[0].fillAll(pattern(0));
    sets[1].fillAll(POISON);
    try mapFixed(space, &sets[0]);
    defer detachFixed(space, pages);

    var reader = Reader{ .space = space, .address = FIXED_VA, .pages = pages };
    space.retain();
    const child = sched.spawn("vm-reader", pinnedReader, &reader, .normal) catch |err| {
        space.release();
        return err;
    };
    defer {
        @atomicStore(bool, &reader.stop, true, .release);
        join(child);
    }
    try waitSeen(&reader, 0);
    for (1..ROUNDS + 1) |round| {
        @atomicStore(u64, &reader.phase, round * 2 - 1, .release);
        const old = &sets[(round - 1) & 1];
        const next = &sets[round & 1];
        detachFixed(space, pages);
        old.fillAll(POISON);
        next.fillAll(pattern(round));
        try mapFixed(space, next);
        @atomicStore(u64, &reader.phase, round * 2, .release);
        try waitSeen(&reader, round * 2);
    }
    console.print("[pass] concurrent user VM: {d} detaches of {d} borrowed pages; a pinned remote TLB never read a poisoned frame\n", .{ ROUNDS, pages });
}

// ── Kernel copies racing detach ─────────────────────────────────────────────

const Copier = struct {
    space: *spaces.AddressSpace,
    stop: bool = false,
    failed: bool = false,
    copies: usize = 0,
    faults: usize = 0,
};

/// Copy the range in and write it back out as fast as possible. Frames are
/// filled before they are mapped, so a successful copy holds one pattern
/// throughout; poison or a mix means an access outlived its frame.
fn copier(arg: ?*anyopaque) void {
    const c: *Copier = @ptrCast(@alignCast(arg.?));
    sched.attachCurrentUserSpace(c.space);
    var buffer: [COPY_PAGES * PAGE]u8 align(8) = undefined;
    while (!@atomicLoad(bool, &c.stop, .acquire)) {
        const pml4 = c.space.pml4;
        if (validate.copyFromUser(pml4, &buffer, FIXED_VA, buffer.len)) |_| {
            const words = std.mem.bytesAsSlice(u64, &buffer);
            const first = words[0];
            var consistent = first >> 48 == 0x5eed;
            for (words) |word| {
                if (word != first) consistent = false;
            }
            if (!consistent) @atomicStore(bool, &c.failed, true, .release);
            // A write-back through a detached frame would overwrite poison.
            validate.copyToUser(pml4, FIXED_VA, &buffer, buffer.len) catch {};
            _ = @atomicRmw(usize, &c.copies, .Add, 1, .monotonic);
        } else |_| {
            _ = @atomicRmw(usize, &c.faults, .Add, 1, .monotonic);
        }
    }
}

fn copyRaceProbe() !void {
    const space = try spaces.AddressSpace.create();
    defer space.release();
    var sets = [2]FrameSet{ try FrameSet.alloc(COPY_PAGES), .{} };
    defer for (&sets) |*set| set.free();
    sets[1] = try FrameSet.alloc(COPY_PAGES);
    sets[0].fillAll(pattern(0));
    sets[1].fillAll(POISON);
    try mapFixed(space, &sets[0]);
    defer detachFixed(space, COPY_PAGES);

    var c = Copier{ .space = space };
    space.retain();
    const child = sched.spawn("vm-copier", copier, &c, .normal) catch |err| {
        space.release();
        return err;
    };
    defer {
        @atomicStore(bool, &c.stop, true, .release);
        join(child);
    }
    const start_deadline = tsc.microsSinceBoot() + 10_000_000;
    while (@atomicLoad(usize, &c.copies, .acquire) == 0) {
        if (tsc.microsSinceBoot() >= start_deadline) return error.CopierDidNotStart;
        sched.sleepMs(1);
    }

    var remote_rounds: usize = 0;
    for (1..COPY_ROUNDS + 1) |round| {
        const old = &sets[(round - 1) & 1];
        const next = &sets[round & 1];
        if (space.residentCpus() != 0) remote_rounds += 1;
        detachFixed(space, COPY_PAGES);
        old.fillAll(POISON);
        // Poisoned when it was detached last round; no access may touch it since.
        if (round > 1 and !next.holds(POISON)) return error.DetachedFrameWritten;
        next.fillAll(pattern(round));
        try mapFixed(space, next);
        if (@atomicLoad(bool, &c.failed, .acquire)) return error.InconsistentCopy;
        // Give the copier the CPU now and then on a single-CPU machine.
        if (round % 16 == 0) sched.sleepMs(1);
    }
    @atomicStore(bool, &c.stop, true, .release);
    if (@atomicLoad(bool, &c.failed, .acquire)) return error.InconsistentCopy;
    if (smp.cpusOnline() > 1 and remote_rounds == 0) return error.CopierNeverResident;
    console.print("[pass] concurrent user VM: {d} detaches raced {d} kernel copies ({d} clean faults), no poisoned read or write\n", .{
        COPY_ROUNDS, @atomicLoad(usize, &c.copies, .acquire), @atomicLoad(usize, &c.faults, .acquire),
    });
}

// ── Drain handshake: an access held across a detach ─────────────────────────
//
// The copy race above rarely overlaps an access with a detach when QEMU runs
// every vCPU round-robin on one host thread. Here the overlap is forced: the
// holder translates a page inside an access and parks there. The coordinator
// detaches, poisons the frame and announces it. A correct drain keeps the
// coordinator inside the detach until the holder leaves, so the holder's park
// times out and its second read still sees the pattern. Without the drain,
// the announcement arrives first and the second read sees poison.

const HOLD_ROUNDS = 8;
const HOLD_MS = 50;

const Holder = struct {
    space: *spaces.AddressSpace,
    request: u64 = 0,
    holding: u64 = 0,
    poisoned: u64 = 0,
    done: u64 = 0,
    stop: bool = false,
    failed: bool = false,
    timeouts: usize = 0,
};

fn holder(arg: ?*anyopaque) void {
    const h: *Holder = @ptrCast(@alignCast(arg.?));
    sched.attachCurrentUserSpace(h.space);
    var last: u64 = 0;
    while (!@atomicLoad(bool, &h.stop, .acquire)) {
        const round = @atomicLoad(u64, &h.request, .acquire);
        if (round == last) {
            sched.sleepMs(1);
            continue;
        }
        last = round;
        const access = h.space.beginAccess();
        const phys = vmm.translate(h.space.pml4, FIXED_VA) orelse {
            access.end();
            @atomicStore(bool, &h.failed, true, .release);
            @atomicStore(u64, &h.done, round, .release);
            continue;
        };
        const words: [*]const volatile u64 = @ptrFromInt(pmm.physToVirt(phys));
        if (words[0] != pattern(round)) @atomicStore(bool, &h.failed, true, .release);
        @atomicStore(u64, &h.holding, round, .release);
        const deadline = tsc.microsSinceBoot() + HOLD_MS * 1000;
        while (@atomicLoad(u64, &h.poisoned, .acquire) != round) {
            if (tsc.microsSinceBoot() >= deadline) {
                h.timeouts += 1;
                break;
            }
            asm volatile ("pause");
        }
        if (words[PAGE / 8 - 1] != pattern(round)) @atomicStore(bool, &h.failed, true, .release);
        access.end();
        @atomicStore(u64, &h.done, round, .release);
    }
}

fn waitRound(value: *const u64, round: u64) !void {
    const deadline = tsc.microsSinceBoot() + 10_000_000;
    while (@atomicLoad(u64, value, .acquire) != round) {
        if (tsc.microsSinceBoot() >= deadline) return error.HolderTimedOut;
        sched.sleepMs(1);
    }
}

fn drainHandshakeProbe() !void {
    const space = try spaces.AddressSpace.create();
    defer space.release();
    var sets = [2]FrameSet{ try FrameSet.alloc(1), .{} };
    defer for (&sets) |*set| set.free();
    sets[1] = try FrameSet.alloc(1);
    sets[1].fillAll(POISON);
    var h = Holder{ .space = space };
    space.retain();
    const child = sched.spawn("vm-holder", holder, &h, .normal) catch |err| {
        space.release();
        return err;
    };
    defer {
        @atomicStore(bool, &h.stop, true, .release);
        join(child);
    }
    for (1..HOLD_ROUNDS + 1) |round| {
        const current = &sets[round & 1];
        current.fillAll(pattern(round));
        try mapFixed(space, current);
        @atomicStore(u64, &h.request, round, .release);
        try waitRound(&h.holding, round);
        // The holder is inside its access now; this must not return first.
        detachFixed(space, 1);
        current.fillAll(POISON);
        @atomicStore(u64, &h.poisoned, round, .release);
        try waitRound(&h.done, round);
        if (@atomicLoad(bool, &h.failed, .acquire)) return error.AccessOutlivedDetach;
    }
    if (h.timeouts != HOLD_ROUNDS) return error.DetachDidNotWait;
    console.print("[pass] concurrent user VM: {d} detaches waited for an in-flight access before the frame was reused\n", .{HOLD_ROUNDS});
}

/// Global free-page totals are not compared here: Seed's runtime probes spawn
/// processes concurrently. Exact conservation of these paths is checked by
/// the single-threaded boot memory tests.
pub fn run() !void {
    if (smp.cpusOnline() > 1) {
        // 8 pages takes the per-page INVLPG path; 48 exceeds the full-flush
        // threshold, so the remote handler reloads CR3 instead.
        try staleTranslationProbe(8, false);
        try staleTranslationProbe(MAX_PAGES, false);
        try staleTranslationProbe(8, true);
        try deterministicTlbProbe(8);
        try deterministicTlbProbe(MAX_PAGES);
    }
    try copyRaceProbe();
    try drainHandshakeProbe();
}
