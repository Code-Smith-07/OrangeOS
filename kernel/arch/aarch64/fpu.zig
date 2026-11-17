//! A task's floating point and SIMD registers on Arm64: q0-q31, then FPSR
//! and FPCR. Switched eagerly with the task, as on x86. The kernel itself
//! is built without these registers, so what is in them always belongs to
//! the program that was running.

pub const State = extern struct {
    q: [32][16]u8 align(16) = [_][16]u8{[_]u8{0} ** 16} ** 32,
    fpsr: u64 = 0,
    fpcr: u64 = 0,
};

extern fn fpuSave(state: *State) callconv(.c) void;
extern fn fpuLoad(state: *const State) callconv(.c) void;

/// The registers as they are right now.
pub fn save(state: *State) void {
    fpuSave(state);
}
pub fn load(state: *const State) void {
    fpuLoad(state);
}

/// Nothing to switch on: boot.S already allows user programs to use them.
pub fn initCpu() void {}
