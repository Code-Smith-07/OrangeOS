//! 8042 PS/2 controller — keyboard and mouse.
//!
//! QEMU's q35 emulates the legacy 8042, and it is still present on most real
//! x86 machines behind an ACPI-declared emulation. USB HID replaces it in
//! Phase 8; until then this is how a mouse and keyboard reach the system.
//!
//! Both devices share one controller and one data port. Which device a byte
//! came from is told by bit 5 of the status register, which is why the two
//! drivers cannot be independent.

const io = @import("../../arch/x86_64/io.zig");
const isr = @import("../../arch/x86_64/isr.zig");
const apic = @import("../../arch/x86_64/apic.zig");
const ioapic = @import("../../arch/x86_64/ioapic.zig");
const madt = @import("../../dev/acpi/madt.zig");
const console = @import("../../console.zig");
const event = @import("event.zig");

const DATA: u16 = 0x60;
const STATUS: u16 = 0x64;
const COMMAND: u16 = 0x64;

const STATUS_OUTPUT_FULL: u8 = 1 << 0;
const STATUS_INPUT_FULL: u8 = 1 << 1;
/// Set when the pending byte came from the second port (the mouse).
const STATUS_FROM_MOUSE: u8 = 1 << 5;

const CMD_READ_CONFIG: u8 = 0x20;
const CMD_WRITE_CONFIG: u8 = 0x60;
const CMD_ENABLE_PORT2: u8 = 0xA8;
const CMD_WRITE_PORT2: u8 = 0xD4;

const CONFIG_PORT1_IRQ: u8 = 1 << 0;
const CONFIG_PORT2_IRQ: u8 = 1 << 1;
const CONFIG_PORT1_CLOCK_OFF: u8 = 1 << 4;
const CONFIG_PORT2_CLOCK_OFF: u8 = 1 << 5;

const MOUSE_SET_DEFAULTS: u8 = 0xF6;
const MOUSE_ENABLE_REPORTING: u8 = 0xF4;

const IRQ_KEYBOARD: u8 = 1;
const IRQ_MOUSE: u8 = 12;
pub const VECTOR_KEYBOARD: u8 = 0x21;
pub const VECTOR_MOUSE: u8 = 0x2C;

fn waitWritable() void {
    var spins: u32 = 0;
    while (spins < 100_000) : (spins += 1) {
        if (io.inb(STATUS) & STATUS_INPUT_FULL == 0) return;
        asm volatile ("pause");
    }
}

fn waitReadable() bool {
    var spins: u32 = 0;
    while (spins < 100_000) : (spins += 1) {
        if (io.inb(STATUS) & STATUS_OUTPUT_FULL != 0) return true;
        asm volatile ("pause");
    }
    return false;
}

fn writeCommand(cmd: u8) void {
    waitWritable();
    io.outb(COMMAND, cmd);
}

fn writeData(value: u8) void {
    waitWritable();
    io.outb(DATA, value);
}

fn writeMouse(value: u8) void {
    writeCommand(CMD_WRITE_PORT2);
    writeData(value);
    // Devices acknowledge with 0xFA. Drain it so it is not mistaken for data.
    if (waitReadable()) _ = io.inb(DATA);
}

// ── Keyboard ────────────────────────────────────────────────────────────────

var extended: bool = false;

fn keyboardHandler(frame: *isr.TrapFrame) void {
    _ = frame;
    while (io.inb(STATUS) & STATUS_OUTPUT_FULL != 0) {
        const status = io.inb(STATUS);
        if (status & STATUS_FROM_MOUSE != 0) {
            mouseByte(io.inb(DATA));
            continue;
        }
        scancode(io.inb(DATA));
    }
    apic.eoi();
}

fn scancode(code: u8) void {
    if (code == 0xE0) {
        extended = true;
        return;
    }

    const released = code & 0x80 != 0;
    const key = code & 0x7F;
    const was_extended = extended;
    extended = false;

    event.pushKey(.{
        .code = key,
        .extended = was_extended,
        .pressed = !released,
    });
}

// ── Mouse ───────────────────────────────────────────────────────────────────
//
// The standard 3-byte packet: flags, then signed X and Y deltas. Y is positive
// upward on the wire and positive downward on screen, so it is negated here
// rather than in every consumer.

var packet: [3]u8 = undefined;
var packet_index: usize = 0;

fn mouseByte(b: u8) void {
    // Bit 3 of the first byte is always set. If it is not, we are out of sync
    // with the packet stream and should not start a packet here.
    if (packet_index == 0 and b & 0x08 == 0) return;

    packet[packet_index] = b;
    packet_index += 1;
    if (packet_index < 3) return;
    packet_index = 0;

    const flags = packet[0];
    // Overflow bits mean the deltas are meaningless; drop the packet.
    if (flags & 0xC0 != 0) return;

    var dx: i32 = packet[1];
    var dy: i32 = packet[2];
    if (flags & 0x10 != 0) dx -= 256; // sign bit for X
    if (flags & 0x20 != 0) dy -= 256; // sign bit for Y

    event.pushMouse(.{
        .dx = dx,
        .dy = -dy,
        .left = flags & 0x01 != 0,
        .right = flags & 0x02 != 0,
        .middle = flags & 0x04 != 0,
    });
}

// ── Bring-up ────────────────────────────────────────────────────────────────

pub fn init() void {
    // Read the configuration byte, enable both ports and both interrupts.
    writeCommand(CMD_READ_CONFIG);
    var config: u8 = if (waitReadable()) io.inb(DATA) else 0;

    config |= CONFIG_PORT1_IRQ | CONFIG_PORT2_IRQ;
    config &= ~(CONFIG_PORT1_CLOCK_OFF | CONFIG_PORT2_CLOCK_OFF);

    writeCommand(CMD_ENABLE_PORT2);
    writeCommand(CMD_WRITE_CONFIG);
    writeData(config);

    // Put the mouse in a known state and tell it to start reporting.
    writeMouse(MOUSE_SET_DEFAULTS);
    writeMouse(MOUSE_ENABLE_REPORTING);

    isr.register(VECTOR_KEYBOARD, keyboardHandler);
    isr.register(VECTOR_MOUSE, keyboardHandler);

    ioapic.routeIrq(IRQ_KEYBOARD, VECTOR_KEYBOARD, 0);
    ioapic.routeIrq(IRQ_MOUSE, VECTOR_MOUSE, 0);
    ioapic.setMasked(madt.gsiForIrq(IRQ_KEYBOARD), false);
    ioapic.setMasked(madt.gsiForIrq(IRQ_MOUSE), false);

    // Drain anything the firmware left pending.
    var drain: u32 = 0;
    while (io.inb(STATUS) & STATUS_OUTPUT_FULL != 0 and drain < 16) : (drain += 1) {
        _ = io.inb(DATA);
    }
}
