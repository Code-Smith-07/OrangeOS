//! Ordinary-process negative probe: even Seed launching this gives no authority.
const pulp = @import("pulp");
export fn _start() callconv(.c) noreturn {
    var key: [64]u8 = undefined;
    for (0..4) |op| {
        if (pulp.syscall3(110, op, @intFromPtr(&key), if (op == 2) 0 else 64) != -13) {
            pulp.puts("host-probe: FAIL unauthorized transport access\n");
            pulp.exit(1);
        }
    }
    pulp.puts("host-probe: PASS all operations denied\n");
    pulp.exit(0);
}
