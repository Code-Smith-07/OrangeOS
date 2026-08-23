//! Kernel panic handler.
//!
//! We implement the panic interface by hand rather than using
//! `std.debug.FullPanic`, because that pulls in std's formatting machinery,
//! which emits SSE instructions. The kernel is compiled with SSE disabled
//! (interrupt entry doesn't save FPU state), so those code paths cannot link.
//!
//! Phase 0 version: report loudly on every console, then park the CPU.
//! Phase 1 replaces this with register dumps and a symbolized backtrace.

const console = @import("console.zig");
const io = @import("arch/x86_64/io.zig");
const fbcon = @import("drivers/video/fbcon.zig");

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    console.write("\n");
    if (fbcon.isReady()) fbcon.setColor(fbcon.theme.accent);
    console.write("================================================\n");
    console.write("  KERNEL PANIC - Zest has stopped\n");
    console.write("================================================\n");
    if (fbcon.isReady()) fbcon.resetColor();

    console.print("  reason: {s}\n", .{msg});
    if (first_trace_addr) |addr| {
        console.print("  at:     0x{x:0>16}\n", .{addr});
    }
    console.write("\n  System halted. Reboot required.\n");

    io.hang();
}

/// The panic interface the compiler expects at the root of the module.
/// Every safety check routes to `panicFn` with a descriptive message.
pub const handler = struct {
    pub const call = panicFn;

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = found;
        panicFn("sentinel mismatch", @returnAddress());
    }
    pub fn unwrapError(err: anyerror) noreturn {
        _ = err;
        panicFn("attempt to unwrap error", @returnAddress());
    }
    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = index;
        _ = len;
        panicFn("index out of bounds", @returnAddress());
    }
    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = start;
        _ = end;
        panicFn("start index is larger than end index", @returnAddress());
    }
    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = accessed;
        panicFn("access of inactive union field", @returnAddress());
    }
    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        panicFn("slice length remainder in cast", @returnAddress());
    }
    pub fn reachedUnreachable() noreturn {
        panicFn("reached unreachable code", @returnAddress());
    }
    pub fn unwrapNull() noreturn {
        panicFn("attempt to use null value", @returnAddress());
    }
    pub fn castToNull() noreturn {
        panicFn("cast causes pointer to be null", @returnAddress());
    }
    pub fn incorrectAlignment() noreturn {
        panicFn("incorrect alignment", @returnAddress());
    }
    pub fn invalidErrorCode() noreturn {
        panicFn("invalid error code", @returnAddress());
    }
    pub fn integerOutOfBounds() noreturn {
        panicFn("integer out of bounds", @returnAddress());
    }
    pub fn integerOverflow() noreturn {
        panicFn("integer overflow", @returnAddress());
    }
    pub fn shlOverflow() noreturn {
        panicFn("left shift overflowed bits", @returnAddress());
    }
    pub fn shrOverflow() noreturn {
        panicFn("right shift overflowed bits", @returnAddress());
    }
    pub fn divideByZero() noreturn {
        panicFn("division by zero", @returnAddress());
    }
    pub fn exactDivisionRemainder() noreturn {
        panicFn("exact division produced a remainder", @returnAddress());
    }
    pub fn integerPartOutOfBounds() noreturn {
        panicFn("integer part out of bounds", @returnAddress());
    }
    pub fn corruptSwitch() noreturn {
        panicFn("switch on corrupt value", @returnAddress());
    }
    pub fn shiftRhsTooBig() noreturn {
        panicFn("shift amount is greater than the type size", @returnAddress());
    }
    pub fn invalidEnumValue() noreturn {
        panicFn("invalid enum value", @returnAddress());
    }
    pub fn forLenMismatch() noreturn {
        panicFn("for loop over objects with non-equal lengths", @returnAddress());
    }
    pub fn copyLenMismatch() noreturn {
        panicFn("source and destination have non-equal lengths", @returnAddress());
    }
    pub fn memcpyAlias() noreturn {
        panicFn("@memcpy arguments alias", @returnAddress());
    }
    pub fn castTruncatedData() noreturn {
        panicFn("integer cast truncated bits", @returnAddress());
    }
    pub fn negativeToUnsigned() noreturn {
        panicFn("attempt to cast negative value to unsigned integer", @returnAddress());
    }
    pub fn memcpyLenMismatch() noreturn {
        panicFn("@memcpy arguments have non-equal lengths", @returnAddress());
    }
    pub fn noreturnReturned() noreturn {
        panicFn("noreturn function returned", @returnAddress());
    }
};
