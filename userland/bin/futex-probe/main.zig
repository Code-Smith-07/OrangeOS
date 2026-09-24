//! Exercise cross-process futex channels, wake limits and error semantics.
const pulp = @import("pulp");

fn waitFor(word: *const u32, target: u32) bool {
    for (0..5000) |_| {
        if (@atomicLoad(u32, word, .seq_cst) >= target) return true;
        pulp.sleepMs(1);
    }
    return false;
}

fn wakeOne(word: *const u32) bool {
    for (0..5000) |_| {
        const n = pulp.wakeWord(word, 1) catch return false;
        if (n == 1) return true;
        if (n != 0) return false;
        pulp.sleepMs(1);
    }
    return false;
}

export fn _start() callconv(.c) noreturn {
    const handle = pulp.shmCreate("runtime.wait", 4096) catch pulp.exit(1);
    const mapping = pulp.shmMap(handle, true) catch pulp.exit(2);
    const words: [*]u32 = @ptrCast(@alignCast(mapping));
    @atomicStore(u32, &words[0], 0, .seq_cst);
    @atomicStore(u32, &words[1], 0, .seq_cst);
    @atomicStore(u32, &words[2], 0, .seq_cst);

    if ((pulp.wakeWord(&words[0], 0) catch pulp.exit(3)) != 0) pulp.exit(4);
    const first = pulp.spawn("/bin/futex-waiter") catch pulp.exit(5);
    const second = pulp.spawn("/bin/futex-waiter") catch pulp.exit(6);
    if (!waitFor(&words[1], 2)) pulp.exit(7);
    if (!wakeOne(&words[0])) pulp.exit(8);
    if (!waitFor(&words[2], 1)) pulp.exit(9);
    if (@atomicLoad(u32, &words[2], .seq_cst) != 1) pulp.exit(10);
    if (!wakeOne(&words[0])) pulp.exit(11);
    if (!waitFor(&words[2], 2)) pulp.exit(12);
    if ((pulp.wait(first) catch pulp.exit(13)) != 0) pulp.exit(14);
    if ((pulp.wait(second) catch pulp.exit(15)) != 0) pulp.exit(16);
    if ((pulp.wakeWord(&words[0], 1) catch pulp.exit(17)) != 0) pulp.exit(18);

    if (pulp.syscall3(pulp.NR.user_wait, @intFromPtr(&words[0]), 1, 1) != -11) pulp.exit(19);
    if (pulp.syscall3(pulp.NR.user_wait, @intFromPtr(&words[0]) + 1, 0, 1) != -22) pulp.exit(20);
    if (pulp.syscall3(pulp.NR.user_wait, 0, 0, 1) != -14) pulp.exit(21);
    if (pulp.syscall2(pulp.NR.user_wake, 0, 1) != -14) pulp.exit(22);
    if (pulp.syscall2(pulp.NR.user_wake, @intFromPtr(&words[0]), 65) != -22) pulp.exit(23);
    pulp.waitWord(&words[0], 0, 5) catch |e| {
        if (e != error.TimedOut) pulp.exit(24);
        if ((pulp.wakeWord(&words[0], 1) catch pulp.exit(26)) != 0) pulp.exit(27);
        pulp.handleClose(handle);
        pulp.puts("futex-probe: PASS shared-frame wake-one, timeout and validation\n");
        pulp.exit(0);
    };
    pulp.exit(25);
}
