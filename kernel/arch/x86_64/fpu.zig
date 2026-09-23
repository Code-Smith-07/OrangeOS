//! Eager x87/MMX/SSE state isolation. Kernel code remains soft-float: interrupt
//! and syscall handlers must not borrow a user's SIMD registers. AVX/XSAVE are
//! intentionally unavailable until we support their larger context format.
const isr = @import("isr.zig");

pub const State = struct {
    bytes: [512]u8 align(16) = initialBytes(),
};

fn initialBytes() [512]u8 {
    var bytes = [_]u8{0} ** 512;
    bytes[0] = 0x7f;
    bytes[1] = 0x03; // x87: masked exceptions, extended precision, nearest
    bytes[24] = 0x80;
    bytes[25] = 0x1f; // MXCSR: masked exceptions, round to nearest
    // FTW=0 (empty stack), zero x87 data/pointers and all sixteen XMM lanes.
    return bytes;
}

/// Called on BSP and every AP before the scheduler can execute user code.
pub fn initCpu() void {
    const features = asm volatile ("cpuid"
        : [edx] "={edx}" (-> u32),
        : [leaf] "{eax}" (@as(u32, 1)),
        : "eax", "ebx", "ecx"
    );
    const required: u32 = (1 << 0) | (1 << 24) | (1 << 25) | (1 << 26);
    if (features & required != required) @panic("CPU requires x87, FXSR and SSE2");
    const cr0 = (isr.readCr0() & ~@as(u64, (1 << 2) | (1 << 3))) | (1 << 1) | (1 << 5);
    asm volatile ("movq %[value], %%cr0"
        :
        : [value] "r" (cr0),
        : "memory"
    );
    const cr4 = (isr.readCr4() & ~@as(u64, 1 << 18)) | (1 << 9) | (1 << 10);
    asm volatile ("movq %[value], %%cr4"
        :
        : [value] "r" (cr4),
        : "memory"
    );
    var clean: State = .{};
    asm volatile ("fxrstor64 (%[state])"
        :
        : [state] "r" (&clean),
        : "memory"
    );
}

test "clean legacy extended state is aligned, empty and deterministic" {
    const std = @import("std");
    const state: State = .{};
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(State));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(State));
    try std.testing.expectEqual(@as(u8, 0), state.bytes[4]);
    try std.testing.expectEqual(@as(u8, 0x7f), state.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x1f), state.bytes[25]);
    for (state.bytes[32..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
