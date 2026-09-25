//! W^X code generation, the pattern a JIT uses: write machine code under
//! read/write, flip it to read/execute, run it; re-patch it under read/write
//! and run the new version. A second thread runs every version too, so each
//! flip must reach the CPU it runs on. Writable+executable is refused.
const std = @import("std");
const pulp = @import("pulp");

const ROUNDS = 64;
const DONE: u32 = 0xffff_fffe;

var code_address: u64 = 0;
var phase: u32 = 0;
var seen: u32 = 0xffff_ffff;
var failed: u32 = 0;

/// mov eax, imm32; ret
fn emit(code: []u8, value: u32) void {
    code[0] = 0xB8;
    std.mem.writeInt(u32, code[1..5], value, .little);
    code[5] = 0xC3;
}

fn call(address: u64) u32 {
    const function: *const fn () callconv(.c) u32 = @ptrFromInt(address);
    return function();
}

/// Runs the code only in even (executable) phases.
fn runner(_: *anyopaque) void {
    var last: u32 = 0xffff_ffff;
    while (true) {
        const current = @atomicLoad(u32, &phase, .acquire);
        if (current == DONE) return;
        if (current % 2 == 0 and current != last) {
            if (call(@atomicLoad(u64, &code_address, .acquire)) != 1000 + current / 2)
                _ = @cmpxchgStrong(u32, &failed, 0, 1, .monotonic, .monotonic);
            last = current;
            @atomicStore(u32, &seen, current, .release);
            _ = pulp.wakeWord(&seen, 1) catch 0;
        }
        asm volatile ("pause");
    }
}

fn waitSeen(target: u32) void {
    while (true) {
        const current = @atomicLoad(u32, &seen, .acquire);
        if (current == target) return;
        pulp.waitWord(&seen, current, 5) catch {};
    }
}

export fn _start() callconv(.c) noreturn {
    const page = pulp.mapMemory(4096, .read_write) catch pulp.exit(1);
    const address = @intFromPtr(page.ptr);
    // Writable and executable at once is refused, both ways in.
    if (pulp.syscall3(pulp.NR.mprotect, address, 4096, 7) != -95) pulp.exit(2);
    if (pulp.syscall3(pulp.NR.mprotect, address, 4096, 6) != -95) pulp.exit(3);
    if (pulp.syscall6(pulp.NR.mmap, 0, 4096, 7, 0x22, std.math.maxInt(u64), 0) != -95) pulp.exit(4);

    emit(page, 1000);
    pulp.protectMemory(page, .read_execute) catch pulp.exit(5);
    if (call(address) != 1000) pulp.exit(6);
    @atomicStore(u64, &code_address, address, .release);

    var context: u8 = 0;
    const thread = pulp.Thread.spawn(runner, &context, 64 * 1024, 0) catch pulp.exit(7);
    waitSeen(0);
    for (1..ROUNDS + 1) |round_index| {
        const round: u32 = @intCast(round_index);
        @atomicStore(u32, &phase, round * 2 - 1, .release);
        pulp.protectMemory(page, .read_write) catch pulp.exit(8);
        emit(page, 1000 + round);
        pulp.protectMemory(page, .read_execute) catch pulp.exit(9);
        if (call(address) != 1000 + round) pulp.exit(10);
        @atomicStore(u32, &phase, round * 2, .release);
        waitSeen(round * 2);
        if (@atomicLoad(u32, &failed, .acquire) != 0) pulp.exit(11);
    }
    @atomicStore(u32, &phase, DONE, .release);
    thread.join();
    pulp.unmapMemory(page) catch pulp.exit(12);
    pulp.print("jit-probe: PASS {d} W^X re-patches run on both threads; RWX refused\n", .{ROUNDS});
    pulp.exit(0);
}
