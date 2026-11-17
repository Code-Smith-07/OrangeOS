//! The wall between the shared kernel and the processor it runs on.
//!
//! Shared code (memory, scheduler, system calls, file systems) imports this
//! file and never a processor directory. Each name below resolves to the
//! module of the same name for the processor being built for, and the two
//! modules offer the same functions. Where a name is an x86 word (gdt, apic,
//! tsc, fsbase), the Arm module of that name does the Arm equivalent: the
//! names are kept so the shared code did not have to change shape.
//!
//!   io       interrupts on/off, wait, pause, stop
//!   percpu   this processor's block, its index, the task it runs
//!   context  switch between kernel threads
//!   fpu      a task's floating point and SIMD registers
//!   fsbase   the user thread pointer
//!   gdt      where the processor finds the kernel stack on entry from user
//!   user     first entry into a user program
//!   smp      other processors: which are online, interrupts between them
//!   isr      interrupt handler registration, the saved-register frame
//!   apic     the interrupt controller and the tick timer
//!   tsc      the fine-grained clock
//!   pte      page table entry encoding
//!   mmu      loading page tables, flushing translations
//!   boot     what the boot loader reported: memory map, kernel location
//!   serial   the log port
//!   rtc      the calendar clock at boot
//!   entropy  hardware random numbers, a fast counter
//!   signal   saving and restoring a user program's registers for signals
const builtin = @import("builtin");

pub const is_x86 = builtin.cpu.arch == .x86_64;
pub const is_arm = builtin.cpu.arch == .aarch64;

pub const io = if (is_x86) @import("x86_64/io.zig") else @import("aarch64/io.zig");
pub const percpu = if (is_x86) @import("x86_64/percpu.zig") else @import("aarch64/percpu.zig");
pub const context = if (is_x86) @import("x86_64/context.zig") else @import("aarch64/context.zig");
pub const fpu = if (is_x86) @import("x86_64/fpu.zig") else @import("aarch64/fpu.zig");
pub const fsbase = if (is_x86) @import("x86_64/fsbase.zig") else @import("aarch64/fsbase.zig");
pub const gdt = if (is_x86) @import("x86_64/gdt.zig") else @import("aarch64/gdt.zig");
pub const user = if (is_x86) @import("x86_64/user.zig") else @import("aarch64/user.zig");
pub const smp = if (is_x86) @import("x86_64/smp.zig") else @import("aarch64/smp.zig");
pub const isr = if (is_x86) @import("x86_64/isr.zig") else @import("aarch64/isr.zig");
pub const apic = if (is_x86) @import("x86_64/apic.zig") else @import("aarch64/apic.zig");
pub const tsc = if (is_x86) @import("../time/tsc.zig") else @import("aarch64/tsc.zig");
pub const pte = if (is_x86) @import("x86_64/pte.zig") else @import("aarch64/pte.zig");
pub const mmu = if (is_x86) @import("x86_64/mmu.zig") else @import("aarch64/mmu.zig");
pub const boot = if (is_x86) @import("../boot/limine_req.zig") else @import("aarch64/bootinfo.zig");
pub const serial = if (is_x86) @import("../drivers/char/serial.zig") else @import("aarch64/serial.zig");
pub const entropy = if (is_x86) @import("x86_64/entropy.zig") else @import("aarch64/entropy.zig");
pub const rtc = if (is_x86) @import("../time/rtc.zig") else @import("aarch64/rtc.zig");
/// x86 keeps its signal frame code in sched/signal.zig, where it was written.
pub const signal = if (is_arm) @import("aarch64/signal_frame.zig") else struct {};
