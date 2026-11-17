//! First entry of a thread into its program on Arm64.

const percpu = @import("percpu.zig");

extern fn enterUserMode(entry: u64, stack: u64, arg: u64, kernel_stack_top: u64) callconv(.c) noreturn;

pub fn enter(entry: u64, stack: u64) noreturn {
    // The program was just written to memory through the data side.
    @import("mmu.zig").syncInstructions();
    enterUserMode(entry, stack, 0, percpu.this().kernel_rsp);
}

pub fn enterWithArg(entry: u64, stack: u64, arg: u64) noreturn {
    @import("mmu.zig").syncInstructions();
    enterUserMode(entry, stack, arg, percpu.this().kernel_rsp);
}
