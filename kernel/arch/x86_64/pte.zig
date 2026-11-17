//! Page table entries on x86-64. The kernel's page flags (mm/page_flags.zig)
//! are the processor's own bits here, so every function is the plain bit
//! operation.
const f = @import("../../mm/page_flags.zig");

pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub inline fn present(entry: u64) bool {
    return entry & f.PRESENT != 0;
}
/// A present entry above the last level that maps memory itself.
pub inline fn huge(entry: u64) bool {
    return entry & f.HUGE != 0;
}
pub inline fn owned(entry: u64) bool {
    return entry & f.OWNED != 0;
}
/// An entry that points at the next table down. `wanted` is USER and/or
/// WRITABLE: x86 requires them at every level of the walk.
pub inline fn table(phys: u64, wanted: u64) u64 {
    return phys | f.PRESENT | f.WRITABLE | wanted;
}
/// An existing table entry, opened up for a mapping that needs `flags`.
pub inline fn widen(entry: u64, wanted: u64) u64 {
    return entry | (wanted & (f.WRITABLE | f.USER));
}
pub inline fn leaf(phys: u64, wanted: u64) u64 {
    return (phys & ADDR_MASK) | wanted | f.PRESENT;
}
pub inline fn block(phys: u64, wanted: u64) u64 {
    return (phys & ADDR_MASK) | wanted | f.PRESENT | f.HUGE;
}
/// The kernel's flags for a present mapping entry.
pub inline fn flagsOf(entry: u64) u64 {
    return entry & ~ADDR_MASK;
}
