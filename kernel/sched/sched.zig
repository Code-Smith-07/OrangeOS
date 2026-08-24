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

pub fn switchCount() u64 {
    return total_switches;
}

pub fn isStarted() bool {
    return started;
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
