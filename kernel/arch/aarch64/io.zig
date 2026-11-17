//! Interrupt masking and waiting on Arm64, under the names the shared
//! kernel uses (they are the x86 instruction names).

const cpu = @import("cpu.zig");

/// Interrupts off on this processor.
pub inline fn cli() void {
    asm volatile ("msr daifset, #2");
}
/// Interrupts on.
pub inline fn sti() void {
    asm volatile ("msr daifclr, #2");
}
pub inline fn interruptsEnabled() bool {
    return cpu.read("daif") & 0x80 == 0;
}
/// Sleep until the next interrupt.
pub inline fn halt() void {
    asm volatile ("wfi");
}
/// A hint inside a spin loop.
pub inline fn pause() void {
    asm volatile ("yield");
}
/// Every earlier store is visible to other processors and devices before
/// anything after this runs.
pub inline fn barrier() void {
    asm volatile ("dsb sy");
}
/// Park the processor for good.
pub fn hang() noreturn {
    cli();
    while (true) halt();
}

// Arm has no I/O ports. PC-only drivers (PS/2, the 8259, port-based PCI
// access) still compile into the kernel because shared code names them;
// nothing starts them on Arm. A read answers "no device there".
pub inline fn outb(_: u16, _: u8) void {}
pub inline fn outw(_: u16, _: u16) void {}
pub inline fn outl(_: u16, _: u32) void {}
pub inline fn inb(_: u16) u8 {
    return 0xFF;
}
pub inline fn inw(_: u16) u16 {
    return 0xFFFF;
}
pub inline fn inl(_: u16) u32 {
    return 0xFFFF_FFFF;
}
pub inline fn ioWait() void {}
