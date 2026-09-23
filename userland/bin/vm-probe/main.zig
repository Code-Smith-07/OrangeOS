//! Ring-3 ABI and protection checks, run with -Druntime-test or from Juice.
const pulp = @import("pulp");
fn require(ok: bool, label: []const u8) void {
    if (!ok) {
        pulp.print("vm-probe: FAIL {s}\n", .{label});
        pulp.exit(1);
    }
}
fn run() !void {
    const memory = try pulp.mapMemory(8193, .read_write);
    require(memory.len == 12288, "page rounding");
    for (memory) |byte| require(byte == 0, "zero initialization");
    @memset(memory, 0xa5);
    try pulp.protectMemory(memory, .read);
    for (memory) |byte| require(byte == 0xa5, "contents after read-only protection");
    const fd = try pulp.open("/etc/motd");
    defer pulp.close(fd);
    require(pulp.syscall3(pulp.NR.read, @intCast(fd), @intFromPtr(memory.ptr), 1) == -14, "kernel refuses writing read-only memory");
    try pulp.protectMemory(memory, .none);
    require(pulp.syscall3(pulp.NR.write, 1, @intFromPtr(memory.ptr), 1) == -14, "PROT_NONE prevents kernel reads");
    try pulp.protectMemory(memory, .read_write);
    memory[0] = 42;
    require(memory[0] == 42, "restored write access");
    const address = @intFromPtr(memory.ptr);
    require(pulp.syscall2(11, address, 4096) == -22, "partial unmap rejected");
    require(pulp.syscall3(12, address, memory.len, 7) == -95, "RWX rejected");
    try pulp.unmapMemory(memory);
    require(pulp.syscall3(1, 1, address, 1) == -14, "released mapping inaccessible");
    require(pulp.syscall2(11, address, 12288) == -22, "double unmap rejected");
    require(pulp.syscall2(11, @intFromPtr(&run), 4096) == -22, "image cannot be unmapped");
    require(pulp.syscall6(10, 0, 0, 3, 0x22, @bitCast(@as(i64, -1)), 0) == -22, "zero length rejected");
    require(pulp.syscall6(10, 0, ~@as(u64, 0), 3, 0x22, @bitCast(@as(i64, -1)), 0) == -22, "overflow rejected");
    require(pulp.syscall6(10, address, 4096, 3, 0x32, @bitCast(@as(i64, -1)), 0) == -95, "fixed mapping rejected");
    for (0..128) |_| {
        const reused = try pulp.mapMemory(65536, .read_write);
        require(@intFromPtr(reused.ptr) == address, "released address reused");
        for (reused) |byte| require(byte == 0, "reused frames cleared");
        @memset(reused, 0x7b);
        try pulp.unmapMemory(reused);
    }
    var slots: [128][]align(4096) u8 = undefined;
    for (&slots) |*slot| slot.* = try pulp.mapMemory(1, .read_write);
    require(pulp.syscall6(10, 0, 4096, 3, 0x22, @bitCast(@as(i64, -1)), 0) == -12, "bounded mapping table");
    for (slots) |slot| try pulp.unmapMemory(slot);
    // Exit cleanup owns this final mapping, even though the app forgets it.
    _ = try pulp.mapMemory(1024 * 1024, .read_write);
    pulp.puts("vm-probe: PASS mapping, protection, rejection, reuse and capacity\n");
}
export fn _start() callconv(.c) noreturn {
    run() catch {
        pulp.puts("vm-probe: FAIL unexpected API error\n");
        pulp.exit(2);
    };
    pulp.exit(0);
}
