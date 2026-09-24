//! Lifetime of a user page table and all mappings backed by it.
//!
//! References keep memory alive independently of task records. They do not
//! authorize concurrent execution: VM mutation, user-copy pinning and scheduler
//! residency/shootdown coordination must be completed before sharing with threads.
const std = @import("std");
const heap = @import("heap.zig");
const vmm = @import("vmm.zig");
const user_vm = @import("user_vm.zig");
const object = @import("../ipc/object.zig");

pub const SHM_REGION_BASE: u64 = 0x0000_6000_0000_0000;

pub const AddressSpace = struct {
    pml4: u64,
    refs: usize = 1,
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
        std.debug.assert(vmm.currentCr3() != self.pml4);
        user_vm.releaseAll(&self.anonymous_vm, self.pml4);
        vmm.destroyAddressSpace(self.pml4);
        // Remove page-table references before returning borrowed SHM frames.
        for (self.mapped_shm) |mapping| {
            if (mapping) |obj| object.release(obj);
        }
        heap.destroy(self);
    }
};
