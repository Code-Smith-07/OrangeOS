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

var current: ?*Task = null;
var idle_task: ?*Task = null;
var task_count: usize = 0;
var started: bool = false;
var need_resched: bool = false;
var last_boost_tick: u64 = 0;

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
    // Interrupts were disabled across the switch that got us here.
    io.sti();

    const t = current orelse unreachable;
    t.entry(t.arg);
    exit(0);
}

pub fn init() !void {
    // The idle thread runs only when nothing else is ready.
    idle_task = try task_mod.create(
        "idle",
        idleLoop,
        null,
        .batch,
        @intFromPtr(&threadTrampoline),
    );
    idle_task.?.state = .ready;
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

/// Highest-priority ready thread, or the idle task.
fn pickNext() *Task {
    var level: usize = 0;
    while (level < task_mod.LEVEL_COUNT) : (level += 1) {
        if (queues[level].pop()) |t| return t;
    }
    return idle_task.?;
}

/// Put a thread back on a run queue according to how it used its quantum.
fn enqueue(t: *Task) void {
    if (t == idle_task.?) return; // the idle task is never queued

    if (t.quantum_left == 0) {
        // Used the whole slice: CPU-bound, so demote.
        t.priority = t.priority.lower();
        t.quantum_left = t.priority.quantumMs();
    }
    t.state = .ready;
    queues[@intFromEnum(t.priority)].push(t);
}

/// Switch to the next runnable thread. Must be called with interrupts off.
fn switchTo(next: *Task) void {
    const prev = current orelse unreachable;
    if (prev == next) return;

    prev.switches += 1;
    total_switches += 1;

    next.state = .running;
    current = next;

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
    defer if (was) io.sti();

    const prev = current orelse return;
    const next = pickNext();
    if (next == prev) return;

    if (prev.state == .running) enqueue(prev);
    switchTo(next);
}

/// Called from the timer interrupt.
pub fn tick() void {
    if (!started) return;

    const t = current orelse return;
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
    const now = time.tickCount();
    if (now - last_boost_tick >= BOOST_INTERVAL_TICKS) {
        last_boost_tick = now;
        boostAll();
    }

    if (t.quantum_left == 0) need_resched = true;
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
    if (!started or !need_resched) return;
    need_resched = false;

    const prev = current orelse return;
    const next = pickNext();
    if (next == prev) {
        // Nothing better to run: give it a fresh slice rather than spinning
        // through the scheduler on every tick.
        if (prev.quantum_left == 0) prev.quantum_left = prev.priority.quantumMs();
        return;
    }

    if (prev.state == .running) enqueue(prev);
    switchTo(next);
}

/// Terminate the current thread. Never returns.
pub fn exit(code: i32) noreturn {
    io.cli();

    const t = current orelse unreachable;
    t.exit_code = code;
    t.state = .zombie;
    task_count -= 1;

    const next = pickNext();
    next.state = .running;
    current = next;

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

    const first = pickNext();
    first.state = .running;
    current = first;
    started = true;
    last_boost_tick = time.tickCount();

    context.contextStart(first.rsp);
    unreachable;
}

pub fn currentTask() ?*Task {
    return current;
}

pub fn taskCount() usize {
    return task_count;
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

    const prev = current orelse return;
    prev.state = .blocked;

    const next = pickNext();
    switchTo(next);

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
