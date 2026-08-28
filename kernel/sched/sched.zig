//! Multi-level feedback queue scheduler.
//!
//! Four priority levels, round-robin within each. The feedback rule is what
//! makes it adaptive without any explicit classification:
//!
//!   - A thread that uses its whole quantum is CPU-bound, so it drops a level.
//!   - A thread that blocks before its quantum expires is interactive, so it
//!     keeps its level.
//!   - Every second, everything is boosted back to level 1, so nothing can be
//!     starved indefinitely by a stream of higher-priority work.
//!
//! Preemption happens from the timer interrupt. Because each thread owns its
//! kernel stack, switching away from inside an interrupt handler is safe: the
//! interrupted state is already saved in a TrapFrame on that thread's own
//! stack, and unwinds normally when the thread is switched back in.
//!
//! ── On SMP ──────────────────────────────────────────────────────────────────
//!
//! Every core runs this scheduler. Two things make that safe:
//!
//! `current` and the idle task are PER CPU, held in each core's own block and
//! reached through GS. A single global `current` would have two cores believing
//! they were running the same task, and both switching away from it.
//!
//! The run queues are shared and every access is under one lock with interrupts
//! masked. A single lock rather than per-CPU queues with work stealing is a
//! deliberate choice: at this core count contention is irrelevant, and a
//! correct simple scheduler is worth far more than a fast racy one. Per-CPU
//! queues are a later optimisation, not a correctness requirement.
//!
//! The lock must be taken with interrupts off. The timer interrupt handler
//! takes it, so a core holding it with interrupts enabled would deadlock
//! against itself the moment its own timer fired.

const std = @import("std");
const task_mod = @import("task.zig");
const context = @import("../arch/x86_64/context.zig");
const spinlock = @import("../sync/spinlock.zig");
const console = @import("../console.zig");
const io = @import("../arch/x86_64/io.zig");
const time = @import("../time/time.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const vmm = @import("../mm/vmm.zig");
const task_mod_kstack = @import("task.zig");

pub const Task = task_mod.Task;
pub const Priority = task_mod.Priority;

/// Anti-starvation boost interval, in ticks.
const BOOST_INTERVAL_TICKS: u64 = 1000;

const Queue = struct {
    head: ?*Task = null,
    tail: ?*Task = null,

    fn push(self: *Queue, t: *Task) void {
        t.next = null;
        if (self.tail) |tail| {
            tail.next = t;
            self.tail = t;
        } else {
            self.head = t;
            self.tail = t;
        }
    }

    fn pop(self: *Queue) ?*Task {
        const t = self.head orelse return null;
        self.head = t.next;
        if (self.head == null) self.tail = null;
        t.next = null;
        return t;
    }

    fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }
};

var queues: [task_mod.LEVEL_COUNT]Queue = [_]Queue{.{}} ** task_mod.LEVEL_COUNT;
var lock: spinlock.SpinLock = .{};

var task_count: usize = 0;
var started: bool = false;
var last_boost_tick: u64 = 0;

/// Per-CPU accessors. The scheduler state lives in each core's own block.
inline fn cpu() *percpu.PerCpu {
    return percpu.this();
}

inline fn currentOf(c: *percpu.PerCpu) ?*Task {
    const p = c.current orelse return null;
    return @ptrCast(@alignCast(p));
}

inline fn idleOf(c: *percpu.PerCpu) ?*Task {
    const p = c.idle orelse return null;
    return @ptrCast(@alignCast(p));
}

var total_switches: u64 = 0;

/// Every task ever created, so a pid can be looked up after it exits.
/// A real system reaps and recycles these; Phase 6 keeps them.
const MAX_TASKS = 64;
var all_tasks: [MAX_TASKS]?*Task = [_]?*Task{null} ** MAX_TASKS;
var all_count: usize = 0;

fn registerTask(t: *Task) void {
    if (all_count >= MAX_TASKS) return;
    all_tasks[all_count] = t;
    all_count += 1;
}

/// Iterate every task ever registered. Used by the budget reporter to
/// attribute CPU time: knowing the machine is busy is useless without knowing
/// which thread is making it busy.
pub fn taskSlotCount() usize {
    return all_count;
}

pub fn taskAt(i: usize) ?*Task {
    if (i >= all_count) return null;
    return all_tasks[i];
}

pub fn findByTid(tid: u32) ?*Task {
    var i: usize = 0;
    while (i < all_count) : (i += 1) {
        if (all_tasks[i]) |t| {
            if (t.tid == tid) return t;
        }
    }
    return null;
}

/// Where a freshly created thread begins. It calls the thread's entry point
/// and cleans up if that ever returns.
export fn threadTrampoline() callconv(.c) void {
    // The switch that got us here released the run-queue lock on the previous
    // CPU's behalf but left interrupts masked. A new thread starts with them on.
    lock.release();
    io.sti();

    const t = currentOf(cpu()) orelse unreachable;
    t.entry(t.arg);
    exit(0);
}

/// Give a core its own idle thread. Every CPU needs one: idle is where a core
/// goes when no work is ready, and two cores cannot share a stack.
pub fn initCpu(index: usize) !void {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "idle/{d}", .{index}) catch "idle";

    const t = try task_mod.create(name, idleLoop, null, .batch, @intFromPtr(&threadTrampoline));
    t.state = .ready;
    percpu.block(index).idle = t;
}

pub fn init() !void {
    try initCpu(0);
}

fn idleLoop(_: ?*anyopaque) void {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Create a thread and make it runnable.
pub fn spawn(
    name: []const u8,
    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
    priority: Priority,
) !*Task {
    const t = try task_mod.create(name, entry, arg, priority, @intFromPtr(&threadTrampoline));

    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    queues[@intFromEnum(priority)].push(t);
    registerTask(t);
    task_count += 1;
    return t;
}

/// Highest-priority ready thread, or this CPU's idle task.
/// Caller must hold `lock`.
fn pickNext(c: *percpu.PerCpu) *Task {
    var level: usize = 0;
    while (level < task_mod.LEVEL_COUNT) : (level += 1) {
        if (queues[level].pop()) |t| return t;
    }
    return idleOf(c).?;
}

/// Put a thread back on a run queue according to how it used its quantum.
/// Caller must hold `lock`.
fn enqueue(c: *percpu.PerCpu, t: *Task) void {
    // Idle tasks belong to their core and are never queued for another to run.
    if (idleOf(c)) |idle| {
        if (t == idle) return;
    }

    if (t.quantum_left == 0) {
        // Used the whole slice: CPU-bound, so demote.
        t.priority = t.priority.lower();
        t.quantum_left = t.priority.quantumMs();
    }
    t.state = .ready;
    queues[@intFromEnum(t.priority)].push(t);
}

/// Switch to the next runnable thread.
/// Caller must hold `lock` with interrupts off; the new thread releases it.
fn switchTo(c: *percpu.PerCpu, next: *Task) void {
    const prev = currentOf(c) orelse unreachable;
    if (prev == next) return;

    prev.switches += 1;
    c.switches += 1;
    _ = @atomicRmw(u64, &total_switches, .Add, 1, .monotonic);

    next.state = .running;
    c.current = next;

    // The CPU has to find a kernel stack when this thread traps or makes a
    // syscall. The TSS covers interrupts from ring 3; the per-CPU block covers
    // syscalls, which do not switch stacks at all.
    const top = task_mod_kstack.kstackTop(next);
    gdt.setKernelStack(top);
    percpu.setKernelStack(top);

    // Switch address spaces if they differ. Reloading CR3 flushes the TLB, so
    // it is worth skipping when both threads share one.
    if (next.address_space != 0 and next.address_space != prev.address_space) {
        vmm.loadCr3(next.address_space);
    }

    context.contextSwitch(&prev.rsp, next.rsp);
}

/// Voluntarily give up the CPU.
pub fn yield() void {
    if (!started) return;

    const was = spinlock.interruptsEnabled();
    io.cli();
    lock.acquire();

    const c = cpu();
    const prev = currentOf(c) orelse {
        lock.release();
        if (was) io.sti();
        return;
    };

    const next = pickNext(c);
    if (next == prev) {
        lock.release();
        if (was) io.sti();
        return;
    }

    if (prev.state == .running) enqueue(c, prev);
    switchTo(c, next);

    // Reaching here means we were switched back in. Whoever resumed us handed
    // over the lock, so we release it.
    lock.release();
    if (was) io.sti();
}

/// Called from the timer interrupt.
pub fn tick() void {
    if (!started) return;

    const c = cpu();
    const t = currentOf(c) orelse return;
    t.ticks_used += 1;

    // Sample what this core was doing when the tick landed.
    if (idleOf(c) == t) c.idle_ticks += 1 else c.busy_ticks += 1;

    // Catch a kernel stack overrun at the first tick after it happens, while
    // the cause is still on the stack, rather than letting it surface later as
    // a jump through a corrupted pointer.
    if (!task_mod.stackIntact(t)) {
        @branchHint(.cold);
        console.err("kernel stack overflow in task \"{s}\" (tid {d})", .{
            t.nameSlice(), t.tid,
        });
        @panic("kernel stack overflow");
    }

    if (t.quantum_left > 0) t.quantum_left -= 1;

    // Wake anything whose sleep deadline has passed. One core does this, the
    // same as the boost below: four cores each walking the list every tick
    // would be three times the lock traffic for the same result.
    if (percpu.cpuIndex() == 0 and sleepers != null) {
        const now_ns = time.monotonicNs();
        const state = spinlock.acquireIrqSave(&lock);
        wakeExpired(now_ns);
        spinlock.releaseIrqRestore(&lock, state);
    }

    // Anti-starvation: periodically lift everything back to interactive.
    // Only one core does this, or four cores would each boost every second.
    if (percpu.cpuIndex() == 0) {
        const now = time.tickCount();
        if (now - last_boost_tick >= BOOST_INTERVAL_TICKS) {
            last_boost_tick = now;
            const state = spinlock.acquireIrqSave(&lock);
            boostAll();
            spinlock.releaseIrqRestore(&lock, state);
        }
    }

    if (t.quantum_left == 0) c.need_resched = true;
}

/// Move every ready thread back to the interactive level.
fn boostAll() void {
    var level: usize = @intFromEnum(Priority.normal);
    while (level < task_mod.LEVEL_COUNT) : (level += 1) {
        while (queues[level].pop()) |t| {
            t.priority = .interactive;
            t.quantum_left = Priority.interactive.quantumMs();
            queues[@intFromEnum(Priority.interactive)].push(t);
        }
    }
}

/// Called at the end of interrupt handling, where switching is safe.
pub fn preemptIfNeeded() void {
    if (!started) return;

    const c = cpu();
    if (!c.need_resched) return;
    c.need_resched = false;

    lock.acquire();

    const prev = currentOf(c) orelse {
        lock.release();
        return;
    };

    const next = pickNext(c);
    if (next == prev) {
        // Nothing better to run: give it a fresh slice rather than spinning
        // through the scheduler on every tick.
        if (prev.quantum_left == 0) prev.quantum_left = prev.priority.quantumMs();
        lock.release();
        return;
    }

    if (prev.state == .running) enqueue(c, prev);
    switchTo(c, next);

    lock.release();
}

/// Terminate the current thread. Never returns.
pub fn exit(code: i32) noreturn {
    io.cli();
    lock.acquire();

    const c = cpu();
    const t = currentOf(c) orelse unreachable;
    t.exit_code = code;
    t.state = .zombie;
    task_count -= 1;

    const next = pickNext(c);
    next.state = .running;
    c.current = next;

    const top = task_mod_kstack.kstackTop(next);
    gdt.setKernelStack(top);
    percpu.setKernelStack(top);
    if (next.address_space != 0 and next.address_space != t.address_space) {
        vmm.loadCr3(next.address_space);
    }

    // The dying thread's stack is still in use until we leave it, so it is
    // freed by whoever reaps it, not here.
    var discard: u64 = 0;
    context.contextSwitch(&discard, next.rsp);
    unreachable;
}

/// Hand the boot context over to the scheduler. Does not return.
pub fn start() noreturn {
    io.cli();
    lock.acquire();

    const c = cpu();
    const first = pickNext(c);
    first.state = .running;
    c.current = first;
    started = true;
    last_boost_tick = time.tickCount();

    // contextStart lands in threadTrampoline, which releases the lock.
    context.contextStart(first.rsp);
    unreachable;
}

/// An application processor enters the scheduler here. It never returns.
pub fn startAp() noreturn {
    io.cli();
    lock.acquire();

    const c = cpu();
    const first = pickNext(c);
    first.state = .running;
    c.current = first;

    context.contextStart(first.rsp);
    unreachable;
}

pub fn currentTask() ?*Task {
    return currentOf(cpu());
}

pub fn taskCount() usize {
    return task_count;
}

/// Per-CPU context switch counts. Evidence that the application processors
/// are genuinely running tasks and not merely halted with the lights on.
pub fn reportCpus(cpu_count: usize) void {
    console.write("[info] scheduler per-CPU switches:");
    var i: usize = 0;
    while (i < cpu_count) : (i += 1) {
        console.print(" cpu{d}={d}", .{ i, percpu.block(i).switches });
    }
    console.write("\n");
}

/// Idle and busy tick samples for one core.
pub fn cpuIdleSamples(index: usize) struct { idle: u64, busy: u64 } {
    const b = percpu.block(index);
    return .{ .idle = b.idle_ticks, .busy = b.busy_ticks };
}

pub fn switchCount() u64 {
    return total_switches;
}

pub fn isStarted() bool {
    return started;
}

/// Threads waiting on a deadline. Intrusive, singly linked through
/// Task.sleep_next, guarded by `lock`.
var sleepers: ?*Task = null;

/// Sleep for `ms`, off the run queue entirely.
///
/// The kernel had no such thing until now: sysSleepMs spun on yield() until
/// the deadline passed, which keeps the thread permanently runnable. With five
/// userland processes doing that - the compositor at 125 Hz, the terminal at
/// 62 Hz, and three more - every core always had work, the idle task never ran
/// once in a three-second window, and the machine burned 100 % of four cores
/// showing a static desktop. For something meant to run on a laptop that is
/// the whole product thesis inverted: a spinning sleep is a flat battery.
pub fn sleepMs(ms: u64) void {
    if (!started or ms == 0) {
        if (ms != 0) time.busySleepMs(ms);
        return;
    }

    const deadline = time.monotonicNs() + ms * 1_000_000;

    const was = spinlock.interruptsEnabled();
    io.cli();
    lock.acquire();

    const c = cpu();
    const prev = currentOf(c) orelse {
        lock.release();
        if (was) io.sti();
        return;
    };

    prev.wake_at_ns = deadline;
    prev.sleep_next = sleepers;
    sleepers = prev;
    prev.state = .blocked;

    const next = pickNext(c);
    switchTo(c, next);

    lock.release();
    if (was) io.sti();
}

/// Move any sleeper whose deadline has passed back onto a run queue.
/// Caller must hold `lock`.
fn wakeExpired(now_ns: u64) void {
    var cur = sleepers;
    var prev_link: ?*Task = null;

    while (cur) |t| {
        const next = t.sleep_next;
        if (t.wake_at_ns <= now_ns) {
            if (prev_link) |p| p.sleep_next = next else sleepers = next;
            t.sleep_next = null;
            t.wake_at_ns = 0;
            // A timed wait that expired is still linked as a waiter.
            if (t.on_wait_list) unlinkWaiter(t);
            if (t.state == .blocked) {
                t.state = .ready;
                queues[@intFromEnum(t.priority)].push(t);
            }
        } else {
            prev_link = t;
        }
        cur = next;
    }
}

// ── Wait queues ─────────────────────────────────────────────────────────────
//
// Waiting on something - a message, a keystroke - used to mean calling yield()
// in a loop. That keeps the thread permanently runnable, so a core can never
// go idle and the "blocked" thread is indistinguishable from a busy one. Four
// servers doing it kept every core at 100 %.
//
// Waking is done by address: `chan` is any stable integer identifying the
// thing being waited on, usually a pointer to it. That avoids threading a wait
// queue through every object type.
//
// The two phases exist to close a lost-wakeup race. Checking a condition and
// then blocking is not atomic: on another core a sender can make the condition
// true and wake the queue in between, and the thread then sleeps forever
// waiting for an event that already happened. So a thread registers itself
// *before* testing the condition. If the wake lands in the window, it unlinks
// the thread, and commitWait sees it is no longer listed and returns without
// sleeping.

var waiters: ?*Task = null;

/// Phase 1: join the queue for `chan` while still runnable.
pub fn prepareWait(chan: usize) void {
    if (!started) return;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    const t = currentOf(cpu()) orelse return;
    if (t.on_wait_list) unlinkWaiter(t);
    t.wait_channel = chan;
    t.wait_next = waiters;
    t.on_wait_list = true;
    waiters = t;
}

/// Leave the queue without sleeping. Used when the condition turned out to be
/// true after all.
pub fn cancelWait() void {
    if (!started) return;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    const t = currentOf(cpu()) orelse return;
    if (t.on_wait_list) unlinkWaiter(t);
}

/// Phase 2 with a bound. `timeout_ms` of 0 waits indefinitely.
pub fn commitWaitTimeout(timeout_ms: u64) void {
    if (!started) {
        asm volatile ("pause");
        return;
    }

    const was = spinlock.interruptsEnabled();
    io.cli();
    lock.acquire();

    const c = cpu();
    const t = currentOf(c) orelse {
        lock.release();
        if (was) io.sti();
        return;
    };

    if (!t.on_wait_list) {
        lock.release();
        if (was) io.sti();
        return;
    }

    if (timeout_ms != 0) {
        t.wake_at_ns = time.monotonicNs() + timeout_ms * 1_000_000;
        t.sleep_next = sleepers;
        sleepers = t;
    }

    t.state = .blocked;
    const next = pickNext(c);
    switchTo(c, next);

    lock.release();
    if (was) io.sti();
}

/// Phase 2: sleep, unless a wake already unlinked us.
pub fn commitWait() void {
    if (!started) {
        asm volatile ("pause");
        return;
    }

    const was = spinlock.interruptsEnabled();
    io.cli();
    lock.acquire();

    const c = cpu();
    const t = currentOf(c) orelse {
        lock.release();
        if (was) io.sti();
        return;
    };

    // The wake beat us here. Nothing to wait for.
    if (!t.on_wait_list) {
        lock.release();
        if (was) io.sti();
        return;
    }

    t.state = .blocked;
    const next = pickNext(c);
    switchTo(c, next);

    lock.release();
    if (was) io.sti();
}

/// Caller must hold `lock`.
fn unlinkSleeper(t: *Task) void {
    var cur = sleepers;
    var prev_link: ?*Task = null;
    while (cur) |x| {
        if (x == t) {
            if (prev_link) |p| p.sleep_next = x.sleep_next else sleepers = x.sleep_next;
            x.sleep_next = null;
            x.wake_at_ns = 0;
            return;
        }
        prev_link = x;
        cur = x.sleep_next;
    }
}

/// Caller must hold `lock`.
fn unlinkWaiter(t: *Task) void {
    var cur = waiters;
    var prev_link: ?*Task = null;
    while (cur) |w| {
        if (w == t) {
            if (prev_link) |p| p.wait_next = w.wait_next else waiters = w.wait_next;
            w.wait_next = null;
            w.on_wait_list = false;
            return;
        }
        prev_link = w;
        cur = w.wait_next;
    }
    t.on_wait_list = false;
}

/// Wake everything waiting on `chan`.
pub fn wakeChannel(chan: usize) void {
    if (!started) return;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    var cur = waiters;
    var prev_link: ?*Task = null;
    while (cur) |w| {
        const next = w.wait_next;
        if (w.wait_channel == chan) {
            if (prev_link) |p| p.wait_next = next else waiters = next;
            w.wait_next = null;
            w.on_wait_list = false;
            // Drop any timeout too. Leaving a stale deadline behind means the
            // next timer sweep wakes this task again, out of whatever it has
            // gone on to block on since - a spurious wakeup that is very hard
            // to trace back to here.
            if (w.wake_at_ns != 0) unlinkSleeper(w);
            // Only queue it if it actually got as far as sleeping. A thread
            // still between prepareWait and commitWait is runnable already,
            // and queueing it twice would put one task on two run queues.
            if (w.state == .blocked) {
                w.state = .ready;
                queues[@intFromEnum(w.priority)].push(w);
            }
        } else {
            prev_link = w;
        }
        cur = next;
    }
}

/// Block the current thread until something wakes it.
pub fn block() void {
    const was = spinlock.interruptsEnabled();
    io.cli();
    lock.acquire();

    const c = cpu();
    const prev = currentOf(c) orelse {
        lock.release();
        if (was) io.sti();
        return;
    };
    prev.state = .blocked;

    const next = pickNext(c);
    switchTo(c, next);

    lock.release();
    if (was) io.sti();
}

/// Make a blocked thread runnable again.
pub fn wake(t: *Task) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    if (t.state != .blocked) return;
    t.state = .ready;
    queues[@intFromEnum(t.priority)].push(t);
}
