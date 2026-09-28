//! Lifetime of a user page table and all mappings backed by it.
//!
//! References keep memory alive independently of task records. Several tasks
//! may execute in one space at once, so every page-table change and every
//! kernel access to user memory follows the protocol below.
//!
//! Changes: `lockVm` pins the CPU and takes the space's VM lock with
//! interrupts left as the caller had them. A change that can leave a stale
//! translation on another CPU then calls `invalidateRange`, which requires
//! interrupts enabled whenever another CPU is resident; while waiting for its
//! acknowledgements the holder keeps servicing other CPUs' shootdowns. Frames
//! and page tables detached by a change are freed only after the invalidation
//! and after `drainAccesses`.
//!
//! Accesses: syscall copies walk the page tables in software and then read or
//! write frames through the HHDM. `beginAccess`/`end` bracket that work so a
//! concurrent unmap cannot free a frame or table mid-copy. Accesses never
//! wait for the VM lock and never sleep, so a writer draining them always
//! finishes.
const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const user_vm = @import("user_vm.zig");
const object = @import("../ipc/object.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const spinlock = @import("../sync/spinlock.zig");
const preempt = @import("../sched/preempt.zig");
const tlb = @import("tlb.zig");

pub const SHM_REGION_BASE: u64 = 0x0000_6000_0000_0000;

pub const AddressSpace = struct {
    pml4: u64,
    refs: usize = 1,
    /// Conservative set of CPUs with this CR3 loaded (including kernel entry).
    /// Scheduler/exec transitions update it with IRQs disabled.
    active_cpus: u64 = 0,
    /// Serializes page-table changes and the mapping metadata below.
    vm_lock: spinlock.SpinLock = .{},
    /// Access epoch and the in-flight access count for each epoch parity.
    access_epoch: u64 = 0,
    access_counts: [2]u32 = .{ 0, 0 },
    anonymous_vm: user_vm.State = .{},
    /// The loaded program image, [image_start, image_end): its pages are
    /// mapped at exec, and mprotect may change them (a program freezing its
    /// own data, as JavaScriptCore does with its configuration page).
    image_start: u64 = 0,
    image_end: u64 = 0,
    shm_next: u64 = SHM_REGION_BASE,
    // Each entry owns one reference, independently of the task's handle table.
    mapped_shm: [128]?*object.Object = [_]?*object.Object{null} ** 128,

    pub fn create() error{OutOfMemory}!*AddressSpace {
        // One page per space, straight from the page allocator: teardown then
        // returns exactly the pages creation took (tests rely on that).
        comptime std.debug.assert(@sizeOf(AddressSpace) <= pmm.PAGE_SIZE);
        const phys = pmm.allocPage() catch return error.OutOfMemory;
        errdefer pmm.freePage(phys);
        const self: *AddressSpace = @ptrFromInt(pmm.physToVirt(phys));
        self.* = .{ .pml4 = try vmm.createAddressSpace() };
        return self;
    }

    /// Caller already owns a live reference; never resurrect a released object.
    pub fn retain(self: *AddressSpace) void {
        const previous = @atomicRmw(usize, &self.refs, .Add, 1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
    }

    /// Drop an owned reference. Switch off this CR3 before dropping the last
    /// reference; no task or borrowed user pointer may outlive its ownership.
    pub fn release(self: *AddressSpace) void {
        const previous = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        std.debug.assert(self.residentCpus() == 0);
        std.debug.assert(vmm.currentCr3() != self.pml4);
        user_vm.releaseAll(self);
        vmm.destroyAddressSpace(self.pml4);
        // Remove page-table references before returning borrowed SHM frames.
        for (self.mapped_shm) |mapping| {
            if (mapping) |obj| object.release(obj);
        }
        pmm.freePage(pmm.virtToPhys(@intFromPtr(self)));
    }

    pub fn residentCpus(self: *const AddressSpace) u64 {
        return @atomicLoad(u64, &self.active_cpus, .seq_cst);
    }

    /// Caller owns a reference and serializes page-table edits separately.
    /// Must accept IPIs while waiting; not yet used by IRQ-masked VM syscalls.
    pub fn invalidate(self: *AddressSpace, address: u64) tlb.Result {
        std.debug.assert(spinlock.interruptsEnabled());
        const pin = preempt.acquire();
        defer pin.release();
        const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
        return tlb.invalidateMask(self.pml4, address, self.residentCpus() & ~self_bit);
    }

    // ── Page-table changes ───────────────────────────────────────────────────

    pub const VmGuard = struct {
        space: *AddressSpace,
        pin: preempt.Guard,

        pub fn unlock(self: VmGuard) void {
            self.space.vm_lock.release();
            self.pin.release();
        }
    };

    /// Pin this CPU and take the VM lock. While another CPU may be resident,
    /// call with interrupts enabled: a holder waiting for acknowledgements
    /// must not be blocked by a contender that cannot take IPIs.
    pub fn lockVm(self: *AddressSpace) VmGuard {
        const pin = preempt.acquire();
        self.vm_lock.acquire();
        return .{ .space = self, .pin = pin };
    }

    /// Invalidate `pages` pages here and on every CPU that may hold them.
    /// Caller holds the VM lock. The resident set is sampled after the page
    /// tables changed: a CPU that joins later loads CR3 afterwards, and that
    /// load cannot return the translations just removed.
    pub fn invalidateRange(self: *AddressSpace, address: u64, pages: usize) void {
        std.debug.assert(percpu.this().preempt_depth != 0);
        if (pages == 0) return;
        const self_bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
        _ = tlb.invalidateRangeMask(self.pml4, address, pages, self.residentCpus() & ~self_bit);
    }

    // ── Kernel accesses to user memory ───────────────────────────────────────

    pub const Access = struct {
        space: *AddressSpace,
        slot: usize,
        pin: preempt.Guard,

        pub fn end(self: Access) void {
            _ = @atomicRmw(u32, &self.space.access_counts[self.slot], .Sub, 1, .release);
            self.pin.release();
        }
    };

    /// Publish an in-flight kernel access to this space's user memory. Every
    /// frame or page table the access can reach stays allocated until `end`.
    /// Short and non-sleeping: the CPU is pinned for the duration.
    pub fn beginAccess(self: *AddressSpace) Access {
        const pin = preempt.acquire();
        while (true) {
            const epoch = @atomicLoad(u64, &self.access_epoch, .seq_cst);
            const slot: usize = @intCast(epoch & 1);
            _ = @atomicRmw(u32, &self.access_counts[slot], .Add, 1, .seq_cst);
            // A writer that flipped the epoch before this count was published
            // might not wait for it, so the count only stands if the epoch is
            // unchanged. The full value is compared: two flips restore the
            // parity but not the number.
            if (@atomicLoad(u64, &self.access_epoch, .seq_cst) == epoch)
                return .{ .space = self, .slot = slot, .pin = pin };
            _ = @atomicRmw(u32, &self.access_counts[slot], .Sub, 1, .release);
        }
    }

    /// Wait until no access that began before this call is still running.
    /// Caller holds the VM lock and has already detached and invalidated what
    /// it is about to free. An access that begins after the flip walks the
    /// changed tables and cannot reach the detached frames.
    pub fn drainAccesses(self: *AddressSpace) void {
        std.debug.assert(percpu.this().preempt_depth != 0);
        const previous = @atomicRmw(u64, &self.access_epoch, .Add, 1, .seq_cst);
        const slot: usize = @intCast(previous & 1);
        while (@atomicLoad(u32, &self.access_counts[slot], .seq_cst) != 0) {
            asm volatile ("pause");
        }
    }

    // ── Borrowed-frame mappings (shared memory, framebuffer) ────────────────

    /// Map `size` bytes of borrowed, physically contiguous frames at the next
    /// shared-mapping address, leaving a guard page after them. Returns the
    /// user address. `owner`, when given, is retained by the space for as long
    /// as the mapping exists. New translations need no remote invalidation.
    pub fn mapBorrowed(self: *AddressSpace, phys: u64, size: usize, flags: u64, owner: ?*object.Object) error{OutOfMemory}!u64 {
        const guard = self.lockVm();
        defer guard.unlock();
        var slot: ?*?*object.Object = null;
        if (owner != null) {
            for (&self.mapped_shm) |*entry| {
                if (entry.* == null) {
                    slot = entry;
                    break;
                }
            }
            if (slot == null) return error.OutOfMemory;
        }
        const base = self.shm_next;
        var off: usize = 0;
        while (off < size) : (off += vmm.PAGE_SIZE) {
            vmm.mapPage(self.pml4, base + off, phys + off, flags) catch {
                // Include the failed page: mapPage may have linked empty
                // tables on its path before running out of memory.
                user_vm.detachLocked(self, base, off + vmm.PAGE_SIZE, false);
                return error.OutOfMemory;
            };
        }
        if (slot) |entry| {
            object.retain(owner.?);
            entry.* = owner;
        }
        self.shm_next = base + size + vmm.PAGE_SIZE;
        return base;
    }
};

/// Both pointers are protected by task-owned references. Publish a new CPU
/// before loading its CR3, then remove the old CPU only AFTER CR3 flushed it.
/// A shootdown racing an entrant either includes it or precedes its CR3 load;
/// an exiting CPU either acknowledges or has already flushed its old entries.
/// No PCID/no-flush CR3 optimization is permitted without revisiting this rule.
pub fn switchTo(previous: ?*AddressSpace, next: ?*AddressSpace) void {
    std.debug.assert(!spinlock.interruptsEnabled());
    std.debug.assert(vmm.currentCr3() == if (previous) |space| space.pml4 else vmm.kernelPml4());
    if (previous == next) return;
    const bit = @as(u64, 1) << @intCast(percpu.cpuIndex());
    if (next) |space| {
        const old = @atomicRmw(u64, &space.active_cpus, .Or, bit, .seq_cst);
        std.debug.assert(old & bit == 0);
    }
    vmm.loadCr3(if (next) |space| space.pml4 else vmm.kernelPml4());
    if (previous) |space| {
        const old = @atomicRmw(u64, &space.active_cpus, .And, ~bit, .seq_cst);
        std.debug.assert(old & bit != 0);
    }
}

/// Bracket a kernel access to the running task's user memory. `pml4` must be
/// the page table the caller validated against; a kernel task or a page table
/// the current task does not own has no concurrent user threads, so it gets
/// no guard.
pub fn beginCurrentAccess(pml4: u64) ?AddressSpace.Access {
    const sched = @import("../sched/sched.zig");
    const task = sched.currentTask() orelse return null;
    const space = task.user_space orelse return null;
    if (space.pml4 != pml4) return null;
    return space.beginAccess();
}
