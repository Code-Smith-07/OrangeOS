//! Arm64 memory management unit.
//!
//! Arm walks two tables: TTBR1 for the upper half of the address space (the
//! kernel) and TTBR0 for the lower half (the running program). The shared
//! kernel thinks in x86 terms, "the current table": here that is TTBR0. A
//! kernel thread runs with the kernel's own table in TTBR0 too; its lower
//! half is empty, so a stray user-address access faults.
//!
//! No address space identifiers are used yet: loading a table drops every
//! cached translation, as an x86 CR3 load without PCID does.

const cpu = @import("cpu.zig");
const pte = @import("pte.zig");

pub const DIRECT_MAP_FROM_ZERO = false;

fn flushAll() void {
    asm volatile (
        \\ tlbi vmalle1
        \\ dsb nsh
        \\ isb
    );
}

pub fn loadRoot(phys: u64) void {
    cpu.write("ttbr0_el1", phys);
    cpu.isb();
    flushAll();
}

pub fn currentRoot() u64 {
    return cpu.read("ttbr0_el1") & pte.ADDR_MASK;
}

/// The kernel's own table, on this processor.
pub fn installKernelRoot(phys: u64) void {
    cpu.write("ttbr1_el1", phys);
    cpu.write("ttbr0_el1", phys);
    cpu.isb();
    flushAll();
}

/// Forget this processor's cached translation of one page, whichever
/// address space it belongs to.
pub fn invalidatePage(virt: u64) void {
    const page = (virt >> 12) & 0xFFF_FFFF_FFFF;
    asm volatile (
        \\ tlbi vaae1, %[page]
        \\ dsb nsh
        \\ isb
        :
        : [page] "r" (page),
    );
}

/// Make code written through the data side visible to instruction fetch on
/// every processor. Arm does not do this by itself: a page of a program
/// just read from disk could otherwise run stale instructions from a cache.
pub fn syncInstructions() void {
    asm volatile (
        \\ dsb ish
        \\ ic ialluis
        \\ dsb ish
        \\ isb
        ::: "memory");
}

/// Arm always applies read-only and no-execute to the kernel itself.
pub fn enableProtections() void {}
pub fn writeProtectEnabled() bool {
    return true;
}
