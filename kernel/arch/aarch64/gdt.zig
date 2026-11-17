//! x86 keeps the kernel stack for entries from user level in a table the
//! processor reads (the TSS, set up beside the GDT). Arm has no such table:
//! the processor continues from the kernel stack pointer it had when it
//! left kernel level. The scheduler's call is kept so the shared code is
//! the same; there is nothing to do.

pub fn setKernelStack(_: u64) void {}
