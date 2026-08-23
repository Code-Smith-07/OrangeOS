//! Legacy 8259 PIC — remapped and masked.
//!
//! We use the APIC, not the PIC. But the PIC powers up with its interrupts
//! mapped onto vectors 0x08-0x0F, which collide with CPU exceptions (#DF is
//! vector 8). A spurious PIC interrupt would look like a double fault.
//!
//! So we remap it out of the exception range first, then mask everything.

const io = @import("io.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;

/// Remap to vectors 0x20-0x2F, then mask every line.
pub fn disable() void {
    // Start initialization; both PICs then expect three more writes.
    io.outb(PIC1_CMD, ICW1_INIT | ICW1_ICW4);
    io.ioWait();
    io.outb(PIC2_CMD, ICW1_INIT | ICW1_ICW4);
    io.ioWait();

    io.outb(PIC1_DATA, 0x20); // master base vector
    io.ioWait();
    io.outb(PIC2_DATA, 0x28); // slave base vector
    io.ioWait();

    io.outb(PIC1_DATA, 4); // slave is on IRQ2
    io.ioWait();
    io.outb(PIC2_DATA, 2); // slave cascade identity
    io.ioWait();

    io.outb(PIC1_DATA, ICW4_8086);
    io.ioWait();
    io.outb(PIC2_DATA, ICW4_8086);
    io.ioWait();

    // Mask all lines. The APIC takes over from here.
    io.outb(PIC1_DATA, 0xFF);
    io.outb(PIC2_DATA, 0xFF);
}
