//! Stack unwinding via frame pointers.
//!
//! The kernel is built with -fno-omit-frame-pointer, so every function keeps
//! the chain: rbp points at [saved rbp][return address]. Walking it gives a
//! call stack without any DWARF parsing.

const console = @import("../console.zig");

// Provided by boot/linker-x86_64.ld.
extern var __kernel_start: u8;
extern var __kernel_end: u8;

/// Kernel virtual addresses live in the top half. Anything below means the
/// chain is corrupt and we should stop rather than fault while panicking.
const KERNEL_MIN: u64 = 0xFFFF_8000_0000_0000;

const MAX_FRAMES = 24;

const Frame = extern struct {
    prev: ?*const Frame,
    return_address: u64,
};

/// Frame pointers live on a kernel stack and are 8-byte aligned by the ABI.
fn plausibleFrame(addr: u64) bool {
    return addr >= KERNEL_MIN and addr % 8 == 0;
}

/// Return addresses point into the kernel image and have NO alignment
/// guarantee — they follow a call instruction, which can end anywhere.
/// Requiring alignment here is what made the first backtrace come out empty.
fn plausibleCode(addr: u64) bool {
    return addr >= @intFromPtr(&__kernel_start) and addr < @intFromPtr(&__kernel_end);
}

/// Print one line of the trace.
fn line(depth: usize, addr: u64) void {
    const off = addr - @intFromPtr(&__kernel_start);
    console.print("  #{d:>2}  0x{x:0>16}  (kernel+0x{x})\n", .{ depth, addr, off });
}

/// Backtrace including the faulting instruction itself as frame #0.
/// `kmain` has no caller — Limine jumps to it — so a fault at the top level
/// legitimately produces a single frame.
pub fn printFrom(rip: u64, rbp: u64) void {
    var depth: usize = 0;
    if (plausibleCode(rip)) {
        line(depth, rip);
        depth += 1;
    }
    walk(rbp, depth);
}

/// Print a backtrace starting from `rbp`. Stops at the first implausible
/// frame — during a panic, giving up quietly beats faulting again.
pub fn print(rbp: u64) void {
    walk(rbp, 0);
}

fn walk(rbp: u64, start_depth: usize) void {
    if (!plausibleFrame(rbp)) {
        console.print("  <no frame pointer chain (rbp=0x{x:0>16})>\n", .{rbp});
        return;
    }

    var frame: ?*const Frame = @ptrFromInt(rbp);
    var depth: usize = start_depth;

    while (frame) |f| {
        if (depth >= MAX_FRAMES) {
            console.write("  ... (truncated)\n");
            break;
        }
        if (!plausibleFrame(@intFromPtr(f))) break;

        const ret = f.return_address;
        if (!plausibleCode(ret)) break;

        line(depth, ret);
        depth += 1;
        frame = f.prev;
    }

    if (depth == start_depth) console.write("  <end of chain>\n");
}

/// Current frame pointer, for panics raised from Zig rather than a trap.
pub inline fn currentRbp() u64 {
    return asm volatile ("movq %%rbp, %[out]"
        : [out] "=r" (-> u64),
    );
}
