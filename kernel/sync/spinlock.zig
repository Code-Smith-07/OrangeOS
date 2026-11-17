//! Spinlocks.
//!
//! The interrupt discipline matters as much as the atomics: if code holds a
//! lock and a timer interrupt preempts it into code that wants the same lock,
//! the CPU deadlocks against itself. `acquireIrqSave` disables interrupts for
//! the duration, which is the only safe way to take a lock that an interrupt
//! handler also takes.
//!
//! The kernel is built with `single_threaded = false`, so these atomics carry
//! LLVM's system (cross-CPU) scope rather than a single-thread one.

const std = @import("std");
const io = @import("../arch/arch.zig").io;

pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            // Tell the CPU this is a spin loop: saves power and avoids a
            // memory-order violation stall on exit.
            @import("../arch/arch.zig").io.pause();
        }
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }

    pub fn tryAcquire(self: *SpinLock) bool {
        return self.locked.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }
};

/// Saved interrupt state, returned by acquireIrqSave and passed back to
/// releaseIrqRestore. Restoring rather than blindly re-enabling matters:
/// the caller may itself have been running with interrupts off.
pub const IrqState = struct {
    enabled: bool,
};

pub fn interruptsEnabled() bool {
    return io.interruptsEnabled();
}

pub fn acquireIrqSave(lock: *SpinLock) IrqState {
    const was = interruptsEnabled();
    io.cli();
    lock.acquire();
    return .{ .enabled = was };
}

pub fn releaseIrqRestore(lock: *SpinLock, state: IrqState) void {
    lock.release();
    if (state.enabled) io.sti();
}

/// Run a critical section with interrupts off, without taking a lock.
pub fn withInterruptsDisabled(comptime f: anytype, args: anytype) @TypeOf(@call(.auto, f, args)) {
    const was = interruptsEnabled();
    io.cli();
    defer if (was) io.sti();
    return @call(.auto, f, args);
}
