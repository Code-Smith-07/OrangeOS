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
const isr = @import("arch/x86_64/isr.zig");
const backtrace = @import("debug/backtrace.zig");

fn banner(title: []const u8) void {
    console.write("\n");
    if (fbcon.isReady()) fbcon.setColor(fbcon.theme.accent);
    console.write("================================================================\n");
    console.print("  {s}\n", .{title});
    console.write("================================================================\n");
    if (fbcon.isReady()) fbcon.resetColor();
}

/// Decode a page-fault error code into something readable.
fn describePageFault(code: u64) void {
    console.print("  fault address (CR2): 0x{x:0>16}\n", .{isr.readCr2()});
    console.print("  cause: {s}, during {s}, in {s} mode{s}\n", .{
        if (code & 1 != 0) "protection violation" else "page not present",
        if (code & 2 != 0) "write" else if (code & 16 != 0) "instruction fetch" else "read",
        if (code & 4 != 0) "user" else "kernel",
        if (code & 8 != 0) ", reserved bit set" else "",
    });
}

/// Called from isrDispatch for any CPU exception without a registered handler.
pub fn exception(frame: *isr.TrapFrame) noreturn {
    @branchHint(.cold);

    const vec: u8 = @truncate(frame.vector);
    const name = if (vec < isr.EXCEPTION_COUNT) isr.exception_names[vec] else "unknown";

    banner("CPU EXCEPTION - Zest has stopped");
    console.print("  vector {d}: {s}\n", .{ vec, name });
    console.print("  error code: 0x{x}\n", .{frame.error_code});

    if (vec == 14) describePageFault(frame.error_code);

    console.write("\n  registers:\n");
    console.print("    rip 0x{x:0>16}   rflags 0x{x:0>16}\n", .{ frame.rip, frame.rflags });
    console.print("    rsp 0x{x:0>16}   rbp    0x{x:0>16}\n", .{ frame.rsp, frame.rbp });
    console.print("    rax 0x{x:0>16}   rbx    0x{x:0>16}\n", .{ frame.rax, frame.rbx });
    console.print("    rcx 0x{x:0>16}   rdx    0x{x:0>16}\n", .{ frame.rcx, frame.rdx });
    console.print("    rsi 0x{x:0>16}   rdi    0x{x:0>16}\n", .{ frame.rsi, frame.rdi });
    console.print("    r8  0x{x:0>16}   r9     0x{x:0>16}\n", .{ frame.r8, frame.r9 });
    console.print("    r10 0x{x:0>16}   r11    0x{x:0>16}\n", .{ frame.r10, frame.r11 });
    console.print("    r12 0x{x:0>16}   r13    0x{x:0>16}\n", .{ frame.r12, frame.r13 });
    console.print("    r14 0x{x:0>16}   r15    0x{x:0>16}\n", .{ frame.r14, frame.r15 });
    console.print("    cs  0x{x:0>4}               ss     0x{x:0>4}\n", .{ frame.cs, frame.ss });
    console.print("    cr0 0x{x:0>16}   cr2    0x{x:0>16}\n", .{ isr.readCr0(), isr.readCr2() });
    console.print("    cr3 0x{x:0>16}   cr4    0x{x:0>16}\n", .{ isr.readCr3(), isr.readCr4() });

    console.write("\n  backtrace:\n");
    backtrace.printFrom(frame.rip, frame.rbp);

    console.write("\n  System halted. Reboot required.\n");
    io.hang();
}

pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    banner("KERNEL PANIC - Zest has stopped");
    console.print("  reason: {s}\n", .{msg});
    if (first_trace_addr) |addr| {
        console.print("  at:     0x{x:0>16}\n", .{addr});
    }

    console.write("\n  backtrace:\n");
    backtrace.print(backtrace.currentRbp());

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
        // Report which error it was. `_ = err` is rejected for error sets, and
        // the name is far more useful than a generic message anyway.
        panicFn(@errorName(err), @returnAddress());
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
