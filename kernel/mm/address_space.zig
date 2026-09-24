//! Lifetime of a user page table and all mappings backed by it.
//!
//! References keep memory alive independently of task records. They do not
//! authorize concurrent user execution: VM mutation and user-copy pinning must
//! still be coordinated before exposing a shared-thread syscall.
const std = @import("std");
const heap = @import("heap.zig");
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
    anonymous_vm: user_vm.State = .{},
    shm_next: u64 = SHM_REGION_BASE,
    // Each entry owns one reference, independently of the task's handle table.
    mapped_shm: [128]?*object.Object = [_]?*object.Object{null} ** 128,

    pub fn create() error{OutOfMemory}!*AddressSpace {
        const self = try heap.create(AddressSpace);
        errdefer heap.destroy(self);
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
        user_vm.releaseAll(&self.anonymous_vm, self.pml4);
        vmm.destroyAddressSpace(self.pml4);
        // Remove page-table references before returning borrowed SHM frames.
        for (self.mapped_shm) |mapping| {
            if (mapping) |obj| object.release(obj);
        }
        heap.destroy(self);
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
