const pulp = @import("pulp");
const Result = extern struct { value: f64, tag: u64 };
extern fn browser_c_arithmetic(f64, f64, u64) callconv(.c) Result;
extern fn browser_c_sum([*]const f64, usize, *const fn (f64, f64) callconv(.c) f64) callconv(.c) f64;
extern fn browser_c_stack(f64, f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) f64;

fn add(a: f64, b: f64) callconv(.c) f64 {
    // Keep live floating-point arguments across a real blocking syscall.
    pulp.sleepMs(1);
    return a + b;
}

fn require(ok: bool) void {
    if (!ok) {
        pulp.puts("c-abi-probe: FAIL floating-point C/Zig ABI\n");
        pulp.exit(1);
    }
}

export fn _start() callconv(.c) noreturn {
    const pid: u64 = @intCast(pulp.getpid());
    const value: f64 = @floatFromInt(pid);
    const values = [_]f64{ value, 0.25, 0.5, 0.125 };
    for (0..32) |i| {
        const result = browser_c_arithmetic(value, 2.0, pid + i);
        require(result.value == value + 0.5 and result.tag == pid + i);
        require(browser_c_sum(&values, values.len, &add) == value + 0.875);
        require(browser_c_stack(value, 1, 2, 3, 4, 5, 6, 7, 8) == value + 36.0);
    }
    pulp.puts("c-abi-probe: PASS SSE2 arithmetic, mixed structs, callbacks, stack arguments and blocking calls\n");
    pulp.exit(0);
}
