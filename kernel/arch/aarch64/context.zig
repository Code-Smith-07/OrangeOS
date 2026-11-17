//! Kernel-thread context switching on Arm64 (the code is in switch.S).

const fpu = @import("fpu.zig");

/// What contextSwitch keeps on a thread's stack, lowest address first.
/// `prepareStack` writes it by hand for a thread that has never run.
pub const Context = extern struct {
    x29: u64 = 0,
    x30: u64 = 0, // where `ret` goes
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
};

pub extern fn contextSwitch(old_sp: *u64, new_sp: u64, old_fpu: *fpu.State, new_fpu: *const fpu.State) callconv(.c) void;
pub extern fn contextStart(new_sp: u64, new_fpu: *const fpu.State) callconv(.c) noreturn;

/// Build a stack for a thread that has never run, so the first switch into
/// it lands at `entry` with the stack pointer 16-byte aligned, as the Arm
/// calling convention requires.
pub fn prepareStack(stack_top: u64, entry: u64) u64 {
    const sp = (stack_top & ~@as(u64, 0xF)) - @sizeOf(Context);
    const ctx: *Context = @ptrFromInt(sp);
    ctx.* = .{ .x30 = entry };
    return sp;
}

/// For the scheduler's self-test: fill registers with known values, spin
/// long enough to be preempted many times, and report whether every value
/// is still there. x19-x23 are kept by contextSwitch; the copies in
/// x10-x14 are kept by the interrupt path, which saves everything.
pub fn registersSurvivePreemption() bool {
    const values = [5]u64{ 0xB0B0B0B0B0B0B0B0, 0x1212121212121212, 0x1313131313131313, 0x1414141414141414, 0x1515151515151515 };
    const ok = asm volatile (
        \\ mov x15, x9
        \\ 1:
        \\ subs x15, x15, #1
        \\ b.ne 1b
        \\ mov x0, #0
        \\ cmp x19, x10
        \\ b.ne 2f
        \\ cmp x20, x11
        \\ b.ne 2f
        \\ cmp x21, x12
        \\ b.ne 2f
        \\ cmp x22, x13
        \\ b.ne 2f
        \\ cmp x23, x14
        \\ b.ne 2f
        \\ mov x0, #1
        \\ 2:
        : [ok] "={x0}" (-> u64),
        : [count] "{x9}" (@as(u64, 30_000_000)),
          [a] "{x19}" (values[0]),
          [b] "{x20}" (values[1]),
          [c] "{x21}" (values[2]),
          [d] "{x22}" (values[3]),
          [e] "{x23}" (values[4]),
          [a2] "{x10}" (values[0]),
          [b2] "{x11}" (values[1]),
          [c2] "{x12}" (values[2]),
          [d2] "{x13}" (values[3]),
          [e2] "{x14}" (values[4]),
        : "x15", "memory"
    );
    return ok == 1;
}
