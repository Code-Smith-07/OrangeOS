//! Ordinary-process negative probe: even Seed launching this gives no authority.
const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    // Reads the actual entry return slot, catching the previous guard-page
    // fault when the kernel entered a C function without a synthetic CALL.
    if (@returnAddress() != 0) pulp.exit(3);
    pulp.puts("host-probe: PASS C entry frame sentinel\n");
    var key: [64]u8 = undefined;
    for (0..4) |op| {
        if (pulp.syscall3(110, op, @intFromPtr(&key), if (op == 2) 0 else 64) != -13) {
            pulp.puts("host-probe: FAIL unauthorized transport access\n");
            pulp.exit(1);
        }
    }
    pulp.puts("host-probe: PASS all operations denied\n");
    if (pulp.syscall3(111, 1, 0, 0) != -13 or pulp.syscall3(111, 1, @intFromPtr(&key), 64) != -13) pulp.exit(2);
    pulp.puts("host-probe: PASS snapshot publication denied\n");
    for (0..6) |op| if (pulp.syscall3(112, op, 0, 0) != -13) pulp.exit(4);
    pulp.puts("host-probe: PASS sound command access denied\n");
    pulp.exit(0);
}
