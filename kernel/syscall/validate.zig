//! User pointer validation.
//!
//! ⚠ THE RULE: the kernel never dereferences a user pointer directly. Ever.
//!
//! Every pointer arriving from ring 3 is hostile until proven otherwise. A
//! single violation is a privilege-escalation vulnerability: a process that
//! passes a kernel address to a syscall that writes through it has just gained
//! arbitrary kernel memory write.
//!
//! This module is the single chokepoint. All of it must pass:
//!   1. the address is in the user half
//!   2. address + length does not overflow
//!   3. the whole range is mapped in the calling process's address space
//!   4. the mapping permits the access being asked for

const vmm = @import("../mm/vmm.zig");

pub const Error = error{Fault};

/// First non-canonical address. Anything at or above this belongs to the
/// kernel half and must never be accepted from userspace.
pub const USER_MAX: u64 = 0x0000_8000_0000_0000;

/// Refuse the lowest 4 MiB outright: it is the null guard region, and a
/// pointer there is a null-derived bug in the caller.
const USER_MIN: u64 = 0x1000;

fn rangeOk(addr: u64, len: usize) bool {
    if (len == 0) return true;
    if (addr < USER_MIN) return false;
    const end = @addWithOverflow(addr, len);
    if (end[1] != 0) return false; // overflowed
    return end[0] <= USER_MAX;
}

/// Verify a user range is mapped with the required permissions.
pub fn check(pml4: u64, addr: u64, len: usize, need_write: bool) Error!void {
    if (!rangeOk(addr, len)) return Error.Fault;
    if (len == 0) return;

    var page = addr & ~@as(u64, vmm.PAGE_SIZE - 1);
    const end = addr + len;

    while (page < end) : (page += vmm.PAGE_SIZE) {
        const flags = vmm.leafFlags(pml4, page) orelse return Error.Fault;
        if (flags & vmm.PRESENT == 0) return Error.Fault;
        // The page must actually belong to userspace, not just be mapped.
        if (flags & vmm.USER == 0) return Error.Fault;
        if (need_write and flags & vmm.WRITABLE == 0) return Error.Fault;
    }
}

/// Copy `len` bytes from user memory into a kernel buffer.
pub fn copyFromUser(pml4: u64, dest: []u8, user_addr: u64, len: usize) Error!void {
    if (len > dest.len) return Error.Fault;
    try check(pml4, user_addr, len, false);

    // Safe now: the range is verified mapped and user-owned. Walk it page by
    // page through the HHDM rather than dereferencing the user address, so
    // this works regardless of which address space is currently loaded.
    var copied: usize = 0;
    while (copied < len) {
        const va = user_addr + copied;
        const phys = vmm.translate(pml4, va) orelse return Error.Fault;
        const page_off = va & (vmm.PAGE_SIZE - 1);
        const chunk = @min(vmm.PAGE_SIZE - page_off, len - copied);
        const src: [*]const u8 = @ptrFromInt(physToVirt(phys));
        @memcpy(dest[copied .. copied + chunk], src[0..chunk]);
        copied += chunk;
    }
}

/// Copy `len` bytes from a kernel buffer into user memory.
pub fn copyToUser(pml4: u64, user_addr: u64, src: []const u8, len: usize) Error!void {
    if (len > src.len) return Error.Fault;
    try check(pml4, user_addr, len, true);

    var copied: usize = 0;
    while (copied < len) {
        const va = user_addr + copied;
        const phys = vmm.translate(pml4, va) orelse return Error.Fault;
        const page_off = va & (vmm.PAGE_SIZE - 1);
        const chunk = @min(vmm.PAGE_SIZE - page_off, len - copied);
        const dst: [*]u8 = @ptrFromInt(physToVirt(phys));
        @memcpy(dst[0..chunk], src[copied .. copied + chunk]);
        copied += chunk;
    }
}

const pmm = @import("../mm/pmm.zig");
inline fn physToVirt(phys: u64) u64 {
    return pmm.physToVirt(phys);
}
