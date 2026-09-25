//! Threads of one program: a remote-TLB check across munmap/mmap, then
//! workers sharing counters under a futex mutex, each with private FS TLS and
//! concurrent anonymous-memory churn, joined through their exit words.
const std = @import("std");
const pulp = @import("pulp");

comptime {
    asm (
        \\.section .text
        \\.global threadProbeCpuId
        \\threadProbeCpuId:
        \\    pushq %rbx
        \\    movl $1, %eax
        \\    cpuid
        \\    shrl $24, %ebx
        \\    movl %ebx, %eax
        \\    popq %rbx
        \\    retq
    );
}

extern fn threadProbeCpuId() callconv(.c) u32;

fn tlsValue() u64 {
    return asm volatile ("movq %%fs:0, %[value]"
        : [value] "=r" (-> u64),
    );
}

const WORKERS = 4;
const ITERATIONS = 4096;
const TLB_ROUNDS = 64;
const DONE: u32 = 0xffff_fffe;

var failed: u32 = 0;
var pid: i64 = 0;

fn fail(code: u32) void {
    _ = @cmpxchgStrong(u32, &failed, 0, code, .monotonic, .monotonic);
}

// ── One thread remaps, another reads through its own TLB ────────────────────

var page_address: u64 = 0;
var phase: u32 = 0;
var seen: u32 = 0xffff_ffff;

fn pattern(round: u32) u64 {
    return 0x7ead_0000_0000_0000 | @as(u64, round);
}

/// Reads the page only in even (stable) phases and never sleeps between them,
/// so a translation left behind by a missing shootdown would be used.
fn tlbReader(_: *anyopaque) void {
    var last: u32 = 0xffff_ffff;
    while (true) {
        const current = @atomicLoad(u32, &phase, .acquire);
        if (current == DONE) return;
        if (current % 2 == 0 and current != last) {
            const address = @atomicLoad(u64, &page_address, .acquire);
            const value = @as(*const volatile u64, @ptrFromInt(address)).*;
            if (value != pattern(current / 2)) fail(20);
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

fn tlbCheck() void {
    var memory = pulp.mapMemory(4096, .read_write) catch pulp.exit(30);
    @as(*u64, @ptrCast(memory.ptr)).* = pattern(0);
    @atomicStore(u64, &page_address, @intFromPtr(memory.ptr), .release);
    var context: u8 = 0;
    const reader = pulp.Thread.spawn(tlbReader, &context, 64 * 1024, 0) catch pulp.exit(31);
    waitSeen(0);
    for (1..TLB_ROUNDS + 1) |round_index| {
        const round: u32 = @intCast(round_index);
        @atomicStore(u32, &phase, round * 2 - 1, .release);
        const old = @intFromPtr(memory.ptr);
        pulp.unmapMemory(memory) catch pulp.exit(32);
        memory = pulp.mapMemory(4096, .read_write) catch pulp.exit(33);
        // First fit reuses the hole: nothing else maps during this check.
        if (@intFromPtr(memory.ptr) != old) pulp.exit(34);
        @as(*u64, @ptrCast(memory.ptr)).* = pattern(round);
        @atomicStore(u32, &phase, round * 2, .release);
        waitSeen(round * 2);
        if (@atomicLoad(u32, &failed, .acquire) != 0) pulp.exit(35);
    }
    @atomicStore(u32, &phase, DONE, .release);
    reader.join();
    pulp.unmapMemory(memory) catch pulp.exit(36);
}

// ── Workers ─────────────────────────────────────────────────────────────────

var mutex: pulp.Mutex = .{};
var guarded: u64 = 0;
var counted: u64 = 0;

const Worker = struct {
    index: usize,
    tls: [2]u64 align(16) = .{ 0, 0 },
    tid: i64 = 0,
    cpus: u64 = 0,
};

fn work(arg: *anyopaque) void {
    const w: *Worker = @ptrCast(@alignCast(arg));
    w.tid = pulp.gettid();
    if (pulp.getpid() != pid or w.tid == pid) fail(1);
    // The creator installed &w.tls as this thread's FS base.
    if (tlsValue() != w.tls[0]) fail(2);
    const mark: u8 = @truncate(w.index + 1);
    for (0..ITERATIONS) |i| {
        _ = @atomicRmw(u64, &counted, .Add, 1, .monotonic);
        mutex.lock();
        guarded += 1;
        mutex.unlock();
        if (i % 256 == 0) {
            w.cpus |= @as(u64, 1) << @intCast(threadProbeCpuId() & 63);
            if (tlsValue() != w.tls[0]) fail(3);
            // Every worker changes its own mappings while the others run.
            const memory = pulp.mapMemory(8192, .read_write) catch {
                fail(4);
                continue;
            };
            memory[0] = mark;
            memory[4096] = mark +% 1;
            pulp.protectMemory(memory, .read) catch fail(5);
            if (memory[0] != mark or memory[4096] != mark +% 1) fail(6);
            pulp.unmapMemory(memory) catch fail(7);
            pulp.yield();
        }
    }
}

export fn _start() callconv(.c) noreturn {
    pid = pulp.getpid();
    if (pulp.gettid() != pid) pulp.exit(10);
    tlbCheck();

    var workers: [WORKERS]Worker = undefined;
    var threads: [WORKERS]pulp.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .index = i };
        w.tls[0] = 0x7150_0000_0000_0000 | i;
        threads[i] = pulp.Thread.spawn(work, w, pulp.Thread.default_stack_size, @intFromPtr(&w.tls)) catch pulp.exit(11);
    }
    var cpus: u64 = 0;
    for (threads, 0..) |thread, i| {
        thread.join();
        cpus |= workers[i].cpus;
        for (workers[0..i]) |earlier| {
            if (earlier.tid == workers[i].tid) pulp.exit(12);
        }
    }
    if (@atomicLoad(u32, &failed, .acquire) != 0) {
        pulp.print("thread-probe: FAIL check {d}\n", .{failed});
        pulp.exit(13);
    }
    if (counted != WORKERS * ITERATIONS or guarded != WORKERS * ITERATIONS) pulp.exit(14);
    pulp.print("thread-probe: PASS pid={d} threads={d} cpus={x}\n", .{ pid, WORKERS + 1, cpus });
    pulp.exit(0);
}
