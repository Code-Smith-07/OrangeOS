//! What happens when the processor is interrupted: timer ticks, and a
//! readable report if the kernel itself faults.

const cpu = @import("cpu.zig");
const gic = @import("gic.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

/// The registers vectors.S saves, in the order it saves them.
pub const Frame = extern struct {
    x: [31]u64,
    return_address: u64,
    saved_state: u64,
};

extern const exception_vectors: u8;

/// On every processor.
pub fn install() void {
    cpu.write("vbar_el1", @intFromPtr(&exception_vectors));
    cpu.isb();
}

/// The self-test's system call number: proves a synchronous exception is
/// taken, handled and returned from.
pub const SELF_TEST_CALL: u16 = 0x4F53; // "OS"
pub var self_test_calls: usize = 0;

const CLASS_SYSTEM_CALL = 0x15;

fn className(class: u64) []const u8 {
    return switch (class) {
        0x00 => "unknown instruction",
        0x07 => "floating point used while switched off",
        0x15 => "system call",
        0x20, 0x21 => "instruction fetch from a bad address",
        0x22 => "misaligned program counter",
        0x24, 0x25 => "data access to a bad address",
        0x26 => "misaligned stack pointer",
        0x3C => "breakpoint",
        else => "other",
    };
}

export fn exceptionEntry(frame: *Frame, slot: u64) callconv(.c) void {
    switch (slot) {
        // Interrupt while in the kernel (5) or in a user program (9).
        5, 9 => {
            const interrupt = gic.acknowledge();
            if (interrupt == gic.SPURIOUS) return;
            if (interrupt == timer.INTERRUPT) timer.tick();
            gic.done(interrupt);
        },
        4 => {
            const syndrome = cpu.read("esr_el1");
            const class = syndrome >> 26;
            if (class == CLASS_SYSTEM_CALL and (syndrome & 0xFFFF) == SELF_TEST_CALL) {
                self_test_calls += 1;
                return; // the return address already points past the call
            }
            crash(frame, slot, syndrome);
        },
        else => crash(frame, slot, cpu.read("esr_el1")),
    }
}

fn crash(frame: *Frame, slot: u64, syndrome: u64) noreturn {
    cpu.interruptsOff();
    uart.emergency("\nKERNEL PANIC (arm64) on processor {d}: {s}\n", .{ cpu.index(), className(syndrome >> 26) });
    uart.emergency("  vector {d}, syndrome 0x{x}, address touched 0x{x}\n", .{ slot, syndrome, cpu.read("far_el1") });
    uart.emergency("  at 0x{x}, called from 0x{x}, state 0x{x}\n", .{ frame.return_address, frame.x[30], frame.saved_state });
    while (true) cpu.waitForInterrupt();
}
