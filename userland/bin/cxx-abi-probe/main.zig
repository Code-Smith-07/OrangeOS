const std = @import("std");
const pulp = @import("pulp");

const Result = extern struct { value: f64, checks: u64 };
extern fn orange_cxx_probe(f64) callconv(.c) Result;
extern var __init_array_start: u8;
extern var __init_array_end: u8;

/// C++ global constructors are called once before this app uses C++ objects.
fn runConstructors() void {
    var address = @intFromPtr(&__init_array_start);
    const end = @intFromPtr(&__init_array_end);
    while (address < end) : (address += @sizeOf(usize)) {
        const slot: *const usize = @ptrFromInt(address);
        const constructor: *const fn () callconv(.c) void = @ptrFromInt(slot.*);
        constructor();
    }
}

export fn orange_cxx_allocate(size: usize) callconv(.c) ?*anyopaque {
    const needed = std.math.add(usize, @max(size, 1), 16) catch return null;
    const mapped = pulp.mapMemory(needed, .read_write) catch return null;
    const length: *usize = @ptrCast(mapped.ptr);
    length.* = mapped.len;
    return @ptrFromInt(@intFromPtr(mapped.ptr) + 16);
}

export fn orange_cxx_release(pointer: ?*anyopaque) callconv(.c) void {
    if (pointer == null) return;
    const base = @intFromPtr(pointer.?) - 16;
    const length: *const usize = @ptrFromInt(base);
    const memory: [*]align(4096) u8 = @ptrFromInt(base);
    pulp.unmapMemory(memory[0..length.*]) catch pulp.exit(91);
}

export fn orange_cxx_out_of_memory() callconv(.c) noreturn {
    pulp.exit(92);
}

export fn _start() callconv(.c) noreturn {
    runConstructors();
    for (0..24) |_| {
        const result = orange_cxx_probe(4.0);
        if (result.value != 8.25 or result.checks != 7) {
            pulp.print("cxx-abi-probe: FAIL value_bits={x} checks={x}\n", .{ @as(u64, @bitCast(result.value)), result.checks });
            pulp.exit(1);
        }
    }
    pulp.puts("cxx-abi-probe: PASS global constructor, virtual dispatch, new/delete and C++/Zig ABI\n");
    pulp.exit(0);
}
