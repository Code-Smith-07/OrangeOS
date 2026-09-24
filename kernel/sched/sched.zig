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
const ipc_object = @import("../ipc/object.zig");
const fsbase = @import("../arch/x86_64/fsbase.zig");

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

/// Live tasks and children awaiting collection. Slots return to the pool when
/// a parent waits, so the limit is concurrent records, not lifetime launches.
pub const MAX_TASKS = 64;
var all_tasks: [MAX_TASKS]?*Task = [_]?*Task{null} ** MAX_TASKS;
var all_count: usize = 0;

/// Caller holds the scheduler lock.
fn registerTask(t: *Task) bool {
    for (&all_tasks, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = t;
        all_count = @max(all_count, i + 1);
        return true;
    }
    return false;
}

/// Iterate the live/reapable task registry. Used by the budget reporter to
/// attribute CPU time: knowing the machine is busy is useless without knowing
/// which thread is making it busy.
pub fn taskSlotCount() usize {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return all_count;
}

pub const TaskSample = struct {
    tid: u32,
    ticks_used: u64,
    name: [task_mod.NAME_LEN]u8,
    name_len: usize,

    pub fn nameSlice(self: *const TaskSample) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Copy accounting data under the registry lock; a reaped Task cannot be
/// returned as a pointer to a concurrent budget reporter.
pub fn taskSample(i: usize) ?TaskSample {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    if (i >= all_count) return null;
    const t = all_tasks[i] orelse return null;
    var sample: TaskSample = .{ .tid = t.tid, .ticks_used = t.ticks_used, .name = undefined, .name_len = t.name_len };
    @memcpy(sample.name[0..t.name_len], t.nameSlice());
    return sample;
}

pub fn findByTid(tid: u32) ?*Task {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    var i: usize = 0;
    while (i < all_count) : (i += 1) {
        if (all_tasks[i]) |t| {
            if (t.tid == tid) return t;
        }
    }
    return null;
}

/// Only the spawning task may wait for a child. This also means a returned
/// pointer stays alive while our single-threaded parent performs wait/reap.
pub fn findChild(tid: u32, parent_tid: u32) ?*Task {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    for (all_tasks[0..all_count]) |candidate| {
        const t = candidate orelse continue;
        if (t.tid == tid and t.parent_tid == parent_tid) return t;
    }
    return null;
}

/// Consume one exited child's status and recycle its registry slot and stack.
/// The caller is its only waiter; user threads must add a shared wait owner.
pub fn reapChild(t: *Task, parent_tid: u32) ?i32 {
    const state = spinlock.acquireIrqSave(&lock);
    if (t.parent_tid != parent_tid or t.state != .zombie) {
        spinlock.releaseIrqRestore(&lock, state);
        return null;
    }
    var found = false;
    for (&all_tasks) |*slot| {
        if (slot.* == t) {
            slot.* = null;
            found = true;
            break;
        }
    }
    const code = t.exit_code;
    spinlock.releaseIrqRestore(&lock, state);
    if (!found) return null;
    task_mod.destroy(t);
    return code;
}

/// A parent may exit without waiting. Detach its children while publishing
/// that exit; the reaper will collect each child after it becomes a zombie.
/// Caller holds the scheduler lock.
fn orphanChildrenLocked(parent_tid: u32) void {
    for (all_tasks[0..all_count]) |candidate| {
        const child = candidate orelse continue;
        if (child.parent_tid == parent_tid) child.parent_tid = 0;
    }
}

/// Remove one unowned zombie under the scheduler lock. The task's former CPU
/// has already switched stacks before releasing that lock, so it is safe to
/// destroy the record after the lock is released.
fn takeOrphanZombie() ?*Task {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    for (&all_tasks) |*slot| {
        const t = slot.* orelse continue;
        if (t.parent_tid != 0 or t.state != .zombie) continue;
        slot.* = null;
        return t;
    }
    return null;
}

/// Long-lived kernel worker. This does not make other global resources
/// process-owned; sockets and descriptors still need their own cleanup paths.
pub fn orphanReaper(_: ?*anyopaque) void {
    while (true) {
        while (takeOrphanZombie()) |t| task_mod.destroy(t);
        sleepMs(50);
    }
}

/// Read the exit result under the same lock that publishes `.zombie`.
pub fn taskExitCode(t: *Task) ?i32 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return if (t.state == .zombie) t.exit_code else null;
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
    return spawnWithPty(name, entry, arg, priority, null);
}

/// Set inherited PTY ownership before the child becomes runnable.
pub fn spawnWithPty(
    name: []const u8,
    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
    priority: Priority,
    pty: ?*ipc_object.Object,
) !*Task {
    const t = try task_mod.create(name, entry, arg, priority, @intFromPtr(&threadTrampoline));
    t.parent_tid = if (currentTask()) |parent| parent.tid else 0;
    if (pty) |obj| {
        ipc_object.retain(obj);
        t.pty = obj;
    }

    const state = spinlock.acquireIrqSave(&lock);
    if (!registerTask(t)) {
        spinlock.releaseIrqRestore(&lock, state);
        if (t.pty) |obj| ipc_object.release(obj);
        task_mod.destroy(t);
        return error.OutOfMemory;
    }
    queues[@intFromEnum(priority)].push(t);
    task_count += 1;
    spinlock.releaseIrqRestore(&lock, state);
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
    fsbase.set(next.fs_base);

    // Run-queue lock and masked interrupts cover both state publication and
    // restore, including migration to a different CPU. Never use lazy #NM.
    context.contextSwitch(&prev.rsp, next.rsp, &prev.fpu, &next.fpu);
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
    // An idle thread has a batch-sized slice, but must never make newly ready
    // work wait for its 64 ticks to expire. This also observes work queued by
    // another CPU, without writing that CPU's non-atomic scheduler flag.
    if (idleOf(c) == t) {
        const state = spinlock.acquireIrqSave(&lock);
        for (&queues) |*q| {
            if (q.head != null) {
                c.need_resched = true;
                break;
            }
        }
        spinlock.releaseIrqRestore(&lock, state);
    }
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
    if (currentTask()) |t| {
        t.files.clear();
        @import("../ipc/ipc.zig").clearInputSinkOwnedBy(t.tid);
        @import("../net/net.zig").socketCloseOwnedBy(t.tid);
        @import("../net/tcp.zig").abortOwnedBy(t.tid);
        @import("../mm/user_vm.zig").releaseAll(&t.anonymous_vm, t.address_space);
        if (t.address_space != 0 and t.address_space != vmm.kernelPml4()) {
            const old_space = t.address_space;
            vmm.loadCr3(vmm.kernelPml4());
            t.address_space = vmm.kernelPml4();
            vmm.destroyAddressSpace(old_space);
        }
        // Address-space teardown must precede releasing borrowed SHM frames.
        for (&t.mapped_shm) |*mapping| {
            if (mapping.*) |obj| ipc_object.release(obj);
            mapping.* = null;
        }
        if (t.pty) |obj| ipc_object.release(obj);
        t.pty = null;
        for (&t.handles.entries) |*entry| {
            if (entry.*) |obj| ipc_object.release(obj);
            entry.* = null;
        }
    }
    lock.acquire();

    const c = cpu();
    const t = currentOf(c) orelse unreachable;
    t.exit_code = code;
    t.state = .zombie;
    orphanChildrenLocked(t.tid);
    task_count -= 1;
    _ = wakeChannelLocked(@intFromPtr(t), std.math.maxInt(usize));

    const next = pickNext(c);
    next.state = .running;
    c.current = next;

    const top = task_mod_kstack.kstackTop(next);
    gdt.setKernelStack(top);
    percpu.setKernelStack(top);
    if (next.address_space != 0 and next.address_space != t.address_space) {
        vmm.loadCr3(next.address_space);
    }
    fsbase.set(next.fs_base);

    // The dying thread's stack is still in use until we leave it, so it is
    // freed by whoever reaps it, not here.
    context.contextStart(next.rsp, &next.fpu);
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
    fsbase.set(first.fs_base);
    context.contextStart(first.rsp, &first.fpu);
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

    fsbase.set(first.fs_base);
    context.contextStart(first.rsp, &first.fpu);
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
            if (t.on_wait_list) {
                t.wait_timed_out = true;
                unlinkWaiter(t);
            }
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
    t.wait_timed_out = false;
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

/// Valid for the current task immediately after commitWaitTimeout returns.
pub fn waitTimedOut() bool {
    const t = currentTask() orelse return false;
    return t.wait_timed_out;
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

    _ = wakeChannelLocked(chan, std.math.maxInt(usize));
}

/// Wake at most `count` waiters, including those registered but not yet asleep.
pub fn wakeChannelN(chan: usize, count: usize) usize {
    if (!started or count == 0) return 0;
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return wakeChannelLocked(chan, count);
}

/// Caller must hold `lock`; process exit uses this to publish completion and
/// wake waiters atomically, without recursively acquiring the scheduler lock.
fn wakeChannelLocked(chan: usize, limit: usize) usize {
    var cur = waiters;
    var prev_link: ?*Task = null;
    var woken: usize = 0;
    while (cur) |w| {
        if (woken == limit) break;
        const next = w.wait_next;
        if (w.wait_channel == chan) {
            woken += 1;
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
                // The next timer epilogue can run the woken task promptly
                // when this core is idle or running lower/equal-priority work.
                // Never context-switch here while the wait-list lock is held.
                const c = cpu();
                if (currentOf(c)) |running| {
                    if (idleOf(c) == running or @intFromEnum(w.priority) <= @intFromEnum(running.priority)) c.need_resched = true;
                }
            }
        } else {
            prev_link = w;
        }
        cur = next;
    }
    return woken;
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
