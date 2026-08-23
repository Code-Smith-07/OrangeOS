//! Interrupt Descriptor Table — 256 vectors.
//!
//! Vectors 0..31 are CPU exceptions and are all installed in Phase 1. The
//! remaining 224 point at stubs too, so a spurious interrupt reports itself
//! instead of triple-faulting.

const gdt = @import("gdt.zig");
const isr = @import("isr.zig");

pub const GateType = enum(u4) {
    interrupt = 0xE, // clears IF on entry
    trap = 0xF, // leaves IF as-is
};

const Entry = packed struct(u128) {
    offset_low: u16 = 0,
    selector: u16 = 0,
    ist: u3 = 0,
    reserved0: u5 = 0,
    gate_type: u4 = 0,
    zero: u1 = 0,
    dpl: u2 = 0,
    present: bool = false,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    reserved1: u32 = 0,

    fn make(handler: u64, ist: u3, gate: GateType, dpl: u2) Entry {
        return .{
            .offset_low = @truncate(handler),
            .selector = gdt.KERNEL_CODE,
            .ist = ist,
            .gate_type = @intFromEnum(gate),
            .dpl = dpl,
            .present = true,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
        };
    }
};

const Idtr = packed struct {
    limit: u16,
    base: u64,
};

var idt: [256]Entry align(16) = [_]Entry{.{}} ** 256;

pub fn setGate(vector: u8, handler: u64, ist: u3, gate: GateType, dpl: u2) void {
    idt[vector] = Entry.make(handler, ist, gate, dpl);
}

pub fn init() void {
    // Install all 256 stubs. Comptime unrolled so each vector gets its own
    // entry point with the right number baked in.
    comptime var v: u16 = 0;
    inline while (v < 256) : (v += 1) {
        const vector: u8 = @intCast(v);
        // Faults that can occur on a bad stack get their own IST stack, so
        // the handler runs somewhere known-good.
        const ist: u3 = switch (vector) {
            8 => gdt.IST_DOUBLE_FAULT, // #DF
            2 => gdt.IST_NMI, // NMI
            18 => gdt.IST_MACHINE_CHECK, // #MC
            else => 0,
        };
        setGate(vector, isr.stubAddress(vector), ist, .interrupt, 0);
    }

    // #BP is reachable from ring 3 by design (int3), so it needs DPL 3.
    setGate(3, isr.stubAddress(3), 0, .trap, 3);

    isr.installDefaults();
    load();
}

fn load() void {
    const idtr = Idtr{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : "memory"
    );
}
