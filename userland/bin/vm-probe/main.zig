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
    try pulp.protectMemory(memory[4096..8192], .read);
    require(pulp.syscall3(pulp.NR.read, @intCast(fd), address + 4096, 1) == -14, "subrange read-only");
    require(memory[0] == 42 and memory[8192] == 0xa5, "adjacent pages survive protect");
    try pulp.protectMemory(memory[4096..8192], .read_write);
    try pulp.unmapMemory(memory[4096..8192]);
    require(pulp.syscall3(1, 1, address + 4096, 1) == -14, "middle page unmapped");
    require(memory[0] == 42 and memory[8192] == 0xa5, "adjacent pages survive unmap");
    require(pulp.syscall3(12, address, 12288, 1) == -22, "protection cannot cross hole");
    require(pulp.syscall3(12, address, memory.len, 7) == -95, "RWX rejected");
    const hole = try pulp.mapMemory(4096, .read_write);
    require(@intFromPtr(hole.ptr) == address + 4096, "middle hole reused");
    for (hole) |byte| require(byte == 0, "middle hole zeroed");
    try pulp.unmapMemory(memory[0..4096]);
    try pulp.unmapMemory(memory[8192..12288]);
    try pulp.unmapMemory(hole);
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
    const reservation = try pulp.reserveMemory(1024 * 1024 * 1024);
    require(reservation.len == 1024 * 1024 * 1024, "large virtual reservation");
    require(pulp.syscall3(pulp.NR.write, 1, reservation.address, 1) == -14, "reserved memory inaccessible");
    const committed = try pulp.commitMemory(reservation, 4096, 4096, .read_write);
    require(committed[0] == 0, "commit starts zeroed");
    committed[0] = 0x69;
    require(pulp.syscall3(pulp.NR.vm_commit, @intFromPtr(committed.ptr), 4096, 3) == -22, "overlapping commit rejected");
    require(pulp.syscall3(pulp.NR.mprotect, reservation.address + 8192, 4096, 1) == -22, "protecting a hole rejected");
    try pulp.decommitMemory(reservation, 4096, 4096);
    require(pulp.syscall3(pulp.NR.write, 1, @intFromPtr(committed.ptr), 1) == -14, "decommitted memory inaccessible");
    const recommitted = try pulp.commitMemory(reservation, 4096, 4096, .read);
    require(recommitted[0] == 0, "recommit starts zeroed");
    require(pulp.syscall3(pulp.NR.read, @intCast(fd), @intFromPtr(recommitted.ptr), 1) == -14, "read-only recommit protected");
    require(pulp.syscall3(pulp.NR.vm_commit, reservation.address + reservation.len, 4096, 3) == -22, "commit outside reservation rejected");
    try pulp.releaseReservedMemory(reservation);
    require(pulp.syscall3(pulp.NR.vm_commit, reservation.address, 4096, 3) == -22, "released reservation unusable");
    // Exit cleanup owns this final mapping, even though the app forgets it.
    _ = try pulp.mapMemory(1024 * 1024, .read_write);
    pulp.puts("vm-probe: PASS mapping, subranges, sparse reservation, protection, reuse and capacity\n");
}
export fn _start() callconv(.c) noreturn {
    run() catch {
        pulp.puts("vm-probe: FAIL unexpected API error\n");
        pulp.exit(2);
    };
    pulp.exit(0);
}
