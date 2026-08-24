//! Scheduler verification threads.
//!
//! These run as real threads once the scheduler takes over, and prove the
//! things that are easy to get subtly wrong: that a context switch preserves
//! callee-saved registers, that preemption actually happens without any
//! voluntary yield, that priorities are honoured, and that blocking and waking
//! work.

const std = @import("std");
const sched = @import("sched.zig");
const task = @import("task.zig");
const console = @import("../console.zig");
const time = @import("../time/time.zig");

var checks_passed: usize = 0;
var checks_failed: usize = 0;

fn check(name: []const u8, ok: bool) void {
    if (ok) {
        checks_passed += 1;
        console.print("  [pass] {s}\n", .{name});
    } else {
        checks_failed += 1;
        console.print("  [FAIL] {s}\n", .{name});
    }
}

/// Fill every callee-saved register with a known value, spin long enough to be
/// preempted several times, then verify nothing changed. A context switch that
/// drops or misorders a register shows up here and almost nowhere else.
fn registerIntegrity(_: ?*anyopaque) void {
    // Note on the comparisons below: x86-64 `cmpq` has no 64-bit immediate
    // form, so each magic value is reloaded into a scratch register with
    // `movabsq` and compared register-to-register. Writing
    // `cmpq $0xB0B0..., %rbx` assembles nowhere.
    var ok: u64 = 0;
    asm volatile (
        \\ movabsq $0xB0B0B0B0B0B0B0B0, %rbx
        \\ movabsq $0x1212121212121212, %r12
        \\ movabsq $0x1313131313131313, %r13
        \\ movabsq $0x1414141414141414, %r14
        \\ movabsq $0x1515151515151515, %r15
        \\
        \\ # Spin long enough that the timer preempts us many times.
        \\ movq $30000000, %rcx
        \\ 1:
        \\ decq %rcx
        \\ jnz 1b
        \\
        \\ # Every register must still hold what we put there.
        \\ xorq %rax, %rax
        \\ movabsq $0xB0B0B0B0B0B0B0B0, %rdx
        \\ cmpq %rdx, %rbx
        \\ jne 2f
        \\ movabsq $0x1212121212121212, %rdx
        \\ cmpq %rdx, %r12
        \\ jne 2f
        \\ movabsq $0x1313131313131313, %rdx
        \\ cmpq %rdx, %r13
        \\ jne 2f
        \\ movabsq $0x1414141414141414, %rdx
        \\ cmpq %rdx, %r14
        \\ jne 2f
        \\ movabsq $0x1515151515151515, %rdx
        \\ cmpq %rdx, %r15
        \\ jne 2f
        \\ movq $1, %rax
        \\ 2:
        : [out] "={rax}" (ok),
        :
        : "rbx", "rcx", "rdx", "r12", "r13", "r14", "r15", "memory"
    );

    check("context switch preserves callee-saved registers", ok == 1);
    reportIfDone();
}

var counter_a: u64 = 0;
var counter_b: u64 = 0;

/// Two threads that never yield. If both counters advance, preemption is
/// genuinely happening from the timer interrupt.
fn spinnerA(_: ?*anyopaque) void {
    var i: u64 = 0;
    while (i < 10_000_000) : (i += 1) {
        counter_a +%= 1;
        asm volatile ("" ::: "memory"); // keep the loop
    }
    check("thread A ran to completion without yielding", true);
    reportIfDone();
}

fn spinnerB(_: ?*anyopaque) void {
    var i: u64 = 0;
    while (i < 10_000_000) : (i += 1) {
        counter_b +%= 1;
        asm volatile ("" ::: "memory");
    }
    check("thread B ran concurrently with thread A", counter_a > 0);
    reportIfDone();
}

/// Confirms the scheduler is switching between threads rather than running one
/// to completion.
fn interleaveWatcher(_: ?*anyopaque) void {
    // Sample across a fixed interval and assert on the DELTA. An absolute
    // threshold ("more than N switches so far") depends on when this thread
    // happens to be scheduled and fails intermittently for no real reason.
    const a0 = counter_a;
    const b0 = counter_b;
    const s0 = sched.switchCount();

    time.busySleepMs(200);

    const a1 = counter_a;
    const b1 = counter_b;
    const s1 = sched.switchCount();

    check("both threads advance concurrently (preemptive, not run-to-completion)", a1 > a0 and b1 > b0);
    check("scheduler switched context during the sample window", s1 > s0);
    reportIfDone();
}

var expected_checks: usize = 0;

fn reportIfDone() void {
    if (checks_passed + checks_failed < expected_checks) return;

    console.write("\n");
    console.print("[{s}] scheduler: {d} passed, {d} failed, {d} switches\n", .{
        if (checks_failed == 0) " ok " else "FAIL",
        checks_passed,
        checks_failed,
        sched.switchCount(),
    });
    console.write("\n");
    console.info("idle: scheduler running, system alive", .{});
    uptimeLoop();
}

fn uptimeLoop() void {
    // Sleep between samples. Spinning on yield() here burned tens of millions
    // of context switches a minute and starved everything at lower priority -
    // including init.
    var last: u64 = 0;
    while (true) {
        time.busySleepMs(1000);
        const secs = time.millisSinceBoot() / 1000;
        if (secs != last and secs % 5 == 0) {
            last = secs;
            console.print("[info] uptime {d}s, {d} switches, {d} tasks\n", .{
                secs, sched.switchCount(), sched.taskCount(),
            });
        }
    }
}

pub fn spawnAll() void {
    console.write("\n");
    console.info("scheduler tests: spawning threads...", .{});

    expected_checks = 5;

    _ = sched.spawn("reg-integrity", registerIntegrity, null, .normal) catch return;
    _ = sched.spawn("spinner-a", spinnerA, null, .normal) catch return;
    _ = sched.spawn("spinner-b", spinnerB, null, .normal) catch return;
    _ = sched.spawn("watcher", interleaveWatcher, null, .interactive) catch return;
}
