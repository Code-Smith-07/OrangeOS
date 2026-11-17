//! What a page mapping may be asked to be. These are the kernel's own
//! names; arch.pte turns them into the processor's page table bits (on x86
//! they happen to be the same bits).
pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const WRITE_THROUGH: u64 = 1 << 3;
pub const NO_CACHE: u64 = 1 << 4;
pub const ACCESSED: u64 = 1 << 5;
pub const DIRTY: u64 = 1 << 6;
pub const HUGE: u64 = 1 << 7;
pub const GLOBAL: u64 = 1 << 8;
/// Software bit: the frame behind this mapping belongs to the address space
/// and is freed with it.
pub const OWNED: u64 = 1 << 9;
pub const NO_EXECUTE: u64 = 1 << 63;
