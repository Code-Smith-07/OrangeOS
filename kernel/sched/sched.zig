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
const address_space = @import("../mm/address_space.zig");
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
        if (t.on_run_queue or t.state == .running or t.state == .zombie) schedulerBug("pushed twice or while running/exited", t);
        t.on_run_queue = true;
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
        t.on_run_queue = false;
        if (t.state != .ready) schedulerBug("dequeued a task that is not ready", t);
        return t;
    }

    fn isEmpty(self: *const Queue) bool {
        return self.head == null;
    }
};

var queues: [task_mod.LEVEL_COUNT]Queue = [_]Queue{.{}} ** task_mod.LEVEL_COUNT;

/// A broken scheduler invariant: report the task on the lock-free emergency
/// path (the console lock may be held) and stop.
fn schedulerBug(what: []const u8, t: *const Task) noreturn {
    @branchHint(.cold);
    var line: [192]u8 = undefined;
    console.emergencyWrite(std.fmt.bufPrint(&line, "SCHED BUG: {s}: task 0x{x} tid {d} state {s} queued {} waiting {} sleeping {}\n", .{
        what, @intFromPtr(t), t.tid, @tagName(t.state), t.on_run_queue, t.on_wait_list, t.wake_at_ns != 0,
    }) catch "SCHED BUG\n");
    @panic("scheduler invariant broken");
}
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
/// A multi-process browser runs hundreds of threads; each costs a 32 KiB
/// kernel stack, so the table itself is not the memory limit.
pub const MAX_TASKS = 1024;
/// Programs alive or awaiting collection. Leaves most of the table to
/// threads, so runaway spawning cannot starve the programs already running.
pub const MAX_PROCESSES = 256;
/// Live threads in one program, so no single program takes the whole table.
pub const MAX_THREADS_PER_PROCESS = 512;
var all_tasks: [MAX_TASKS]?*Task = [_]?*Task{null} ** MAX_TASKS;
var all_count: usize = 0;
/// Program leaders in `all_tasks`.
var process_records: usize = 0;

/// Caller holds the scheduler lock.
fn registerTask(t: *Task) bool {
    const leader = isProgramLeader(t);
    if (leader and process_records >= MAX_PROCESSES) return false;
    for (&all_tasks, 0..) |*slot, i| {
        if (slot.* != null) continue;
        slot.* = t;
        all_count = @max(all_count, i + 1);
        if (leader) process_records += 1;
        return true;
    }
    return false;
}

fn isProgramLeader(t: *const Task) bool {
    return t.process != null and t.isLeader();
}

/// Caller holds the scheduler lock; `slot` holds a finished record.
fn forgetSlotLocked(slot: *?*Task) void {
    if (isProgramLeader(slot.*.?)) process_records -= 1;
    slot.* = null;
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

/// Caller holds the scheduler lock.
fn findChildLocked(tid: u32, parent_id: u32) ?*Task {
    for (all_tasks[0..all_count]) |candidate| {
        const t = candidate orelse continue;
        if (t.tid == tid and t.parent_tid == parent_id) return t;
    }
    return null;
}

/// Whether a zombie record may be collected. A program's leader stays until
/// every thread of the program has exited and released its resources; any
/// other thread, and every kernel task, is finished once it is a zombie.
/// Caller holds the scheduler lock.
fn finishedLocked(t: *const Task) bool {
    if (t.state != .zombie) return false;
    const p = t.process orelse return true;
    return !t.isLeader() or p.exited;
}

fn exitCodeOf(t: *const Task) i32 {
    return if (t.process) |p| p.exit_code else t.exit_code;
}

/// The channel woken when `t` can be collected: its process for a user
/// program, the task itself for a kernel task.
pub fn exitChannel(t: *const Task) usize {
    return if (t.process) |p| @intFromPtr(p) else @intFromPtr(t);
}

/// Caller holds the scheduler lock; the record must be finished.
fn unregisterLocked(t: *Task) bool {
    for (&all_tasks) |*slot| {
        if (slot.* == t) {
            forgetSlotLocked(slot);
            return true;
        }
    }
    return false;
}

/// Consume one exited kernel child's status and recycle its registry slot and
/// stack. The caller is the child's only waiter, so `t` stays valid.
pub fn reapChild(t: *Task, parent_tid: u32) ?i32 {
    const state = spinlock.acquireIrqSave(&lock);
    if (t.parent_tid != parent_tid or !finishedLocked(t) or !unregisterLocked(t)) {
        spinlock.releaseIrqRestore(&lock, state);
        return null;
    }
    const code = exitCodeOf(t);
    spinlock.releaseIrqRestore(&lock, state);
    task_mod.destroy(t);
    return code;
}

pub const ChildStatus = union(enum) {
    /// The child's whole program has finished; its record is gone now.
    exited: i32,
    /// Still running. Wait on `channel`, then look the child up again.
    running: usize,
    /// No such child of this owner (never existed, or already collected).
    missing,
};

/// Look up a child by id and consume its status if it has finished. The child
/// is found afresh under the lock on every call, so no task pointer is held
/// across a sleep: another thread of the same parent may collect it first.
pub fn collectChild(tid: u32, parent_id: u32) ChildStatus {
    const state = spinlock.acquireIrqSave(&lock);
    const t = findChildLocked(tid, parent_id) orelse {
        spinlock.releaseIrqRestore(&lock, state);
        return .missing;
    };
    if (!finishedLocked(t)) {
        const channel = exitChannel(t);
        spinlock.releaseIrqRestore(&lock, state);
        return .{ .running = channel };
    }
    std.debug.assert(unregisterLocked(t));
    const code = exitCodeOf(t);
    spinlock.releaseIrqRestore(&lock, state);
    task_mod.destroy(t);
    return .{ .exited = code };
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

/// Remove one unowned finished record under the scheduler lock. The task's
/// former CPU has already switched stacks before releasing that lock, so it is
/// safe to destroy the record after the lock is released.
fn takeOrphanZombie() ?*Task {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    for (&all_tasks) |*slot| {
        const t = slot.* orelse continue;
        if (t.parent_tid != 0 or !finishedLocked(t)) continue;
        forgetSlotLocked(slot);
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
    return if (finishedLocked(t)) exitCodeOf(t) else null;
}

/// Where a freshly created thread begins. It calls the thread's entry point
/// and cleans up if that ever returns.
export fn threadTrampoline() callconv(.c) void {
    // The switch that got us here released the run-queue lock on the previous
    // CPU's behalf but left interrupts masked. A new thread starts with them on.
    // Identify the thread before enabling interrupts. Once they are on it can
    // be preempted and resumed on another CPU, whose own current task is not
    // this one; reading `cpu().current` then ran another thread's entry with
    // that thread's (long since consumed) argument.
    const t = currentOf(cpu()) orelse unreachable;
    lock.release();
    io.sti();

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

/// Create a kernel thread and make it runnable.
pub fn spawn(
    name: []const u8,
    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
    priority: Priority,
) !*Task {
    const t = try task_mod.create(name, entry, arg, priority, @intFromPtr(&threadTrampoline));
    return enqueueNew(t);
}

/// What a new user program starts with. Everything else begins empty.
pub const ProcessInit = struct {
    pty: ?*ipc_object.Object = null,
    service_manager: bool = false,
    host_bridge: bool = false,
    host_controls: bool = false,
};

/// Create the first thread of a new user program. Its process record, stdio
/// binding and boot-issued authority are installed before it can run, so
/// nothing observes a half-built process.
pub fn spawnProcess(
    name: []const u8,
    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
    priority: Priority,
    setup: ProcessInit,
) !*Task {
    const t = try task_mod.create(name, entry, arg, priority, @intFromPtr(&threadTrampoline));
    const p = task_mod.Process.create(t.tid) catch {
        task_mod.destroy(t);
        return error.OutOfMemory;
    };
    p.service_manager = setup.service_manager;
    p.host_bridge = setup.host_bridge;
    p.host_controls = setup.host_controls;
    if (setup.pty) |obj| {
        ipc_object.retain(obj);
        p.pty = obj;
    }
    t.process = p;
    return enqueueNew(t);
}

/// Where a new user thread starts, and what it gets from its creator.
pub const UserThreadStart = struct {
    entry: u64,
    stack: u64,
    arg: u64,
    fs_base: u64,
    exit_word: u64,
};

/// Start another thread of the calling user program. It shares the program's
/// process record and address space and first runs `trampoline` in the
/// kernel, which enters ring 3 at `request.entry`. Nobody waits on the record:
/// the orphan reaper collects it after it exits. Refused once the program
/// has begun exiting, so no thread can escape a group exit.
pub fn spawnUserThread(
    creator: *Task,
    trampoline: *const fn (?*anyopaque) void,
    request: UserThreadStart,
) !*Task {
    const p = creator.process orelse return error.NotUserThread;
    const space = creator.user_space orelse return error.NotUserThread;
    const t = try task_mod.create(creator.nameSlice(), trampoline, null, .normal, @intFromPtr(&threadTrampoline));
    p.retain();
    t.process = p;
    space.retain();
    t.user_space = space;
    t.fs_base = request.fs_base;
    t.exit_word = request.exit_word;
    t.user_entry = request.entry;
    t.user_stack = request.stack;
    t.user_arg = request.arg;

    const state = spinlock.acquireIrqSave(&lock);
    const at_limit = @atomicLoad(u32, &p.live_threads, .acquire) >= MAX_THREADS_PER_PROCESS;
    if (p.exiting or at_limit or !registerTask(t)) {
        const exiting = p.exiting;
        spinlock.releaseIrqRestore(&lock, state);
        t.user_space = null;
        space.release();
        task_mod.destroy(t);
        return if (exiting) error.ProcessExiting else error.OutOfMemory;
    }
    // The creator is a live thread, so this never revives a finished program.
    _ = @atomicRmw(u32, &p.live_threads, .Add, 1, .acq_rel);
    queues[@intFromEnum(t.priority)].push(t);
    task_count += 1;
    spinlock.releaseIrqRestore(&lock, state);
    return t;
}

/// Whether the running thread must leave because its program is exiting.
pub fn killPending() bool {
    const t = currentTask() orelse return false;
    return @atomicLoad(bool, &t.kill_pending, .acquire);
}

/// End every thread of the calling program; the caller exits immediately.
/// Other threads are flagged under the scheduler lock and, if blocked, made
/// runnable. Each then leaves at its next return towards user mode or
/// attempt to block. The first exit code recorded wins.
pub fn exitGroup(code: i32) noreturn {
    const t = currentTask() orelse unreachable;
    if (t.process) |p| {
        const state = spinlock.acquireIrqSave(&lock);
        if (!p.exiting) {
            p.exiting = true;
            p.exit_code = code;
        }
        for (all_tasks[0..all_count]) |candidate| {
            const other = candidate orelse continue;
            if (other == t or other.process != p) continue;
            @atomicStore(bool, &other.kill_pending, true, .release);
            if (other.state == .blocked) {
                if (other.on_wait_list) unlinkWaiter(other);
                if (other.wake_at_ns != 0) unlinkSleeper(other);
                other.state = .ready;
                queues[@intFromEnum(other.priority)].push(other);
            }
        }
        spinlock.releaseIrqRestore(&lock, state);
    }
    exit(code);
}

/// Record the spawner as the owner that may collect this task, then publish
/// it. On failure the unpublished task and anything it holds are released.
fn enqueueNew(t: *Task) !*Task {
    t.parent_tid = if (currentTask()) |parent| parent.ownerId() else 0;
    const state = spinlock.acquireIrqSave(&lock);
    if (!registerTask(t)) {
        spinlock.releaseIrqRestore(&lock, state);
        if (t.process) |p| {
            if (p.pty) |obj| ipc_object.release(obj);
            p.pty = null;
        }
        task_mod.destroy(t);
        return error.OutOfMemory;
    }
    queues[@intFromEnum(t.priority)].push(t);
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
    std.debug.assert(c.preempt_depth == 0);
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
    address_space.switchTo(prev.user_space, next.user_space);
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
    if (!c.need_resched or c.preempt_depth != 0) return;
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
///
/// The last thread of a user program also releases the program's resources
/// and publishes its exit. The atomic decrement picks exactly one last thread
/// even when several exit at once on different CPUs.
pub fn exit(code: i32) noreturn {
    io.cli();
    std.debug.assert(cpu().preempt_depth == 0);
    const t = currentOf(cpu()) orelse unreachable;
    const process = t.process;
    const last = if (process) |p| @atomicRmw(u32, &p.live_threads, .Sub, 1, .acq_rel) == 1 else false;
    if (last) {
        const p = process.?;
        p.files.clear();
        @import("../ipc/ipc.zig").clearInputSinkOwnedBy(p.pid);
        @import("../net/net.zig").socketCloseOwnedBy(p.pid);
        @import("../net/tcp.zig").abortOwnedBy(p.pid);
    }
    // Each thread holds its own address-space reference; the last one out
    // tears the mappings down, before borrowed frames lose their handles.
    if (t.user_space) |space| {
        address_space.switchTo(space, null);
        t.user_space = null;
        space.release();
    }
    if (last) {
        const p = process.?;
        if (p.pty) |obj| ipc_object.release(obj);
        p.pty = null;
        p.handles.releaseAll();
    }
    lock.acquire();

    const c = cpu();
    std.debug.assert(currentOf(c) == t);
    // Once reaped, a task still linked as a waiter or sleeper would be a
    // dangling pointer that a later wake queues again.
    if (t.on_wait_list or t.wake_at_ns != 0 or t.on_run_queue) schedulerBug("exiting while still linked", t);
    t.exit_code = code;
    t.state = .zombie;
    if (process) |p| {
        if (last) {
            // A program ended by exitGroup keeps the code it was ended with;
            // otherwise the last thread's status becomes the program's.
            if (!p.exiting) p.exit_code = code;
            p.exited = true;
            orphanChildrenLocked(p.pid);
            _ = wakeChannelLocked(@intFromPtr(p), std.math.maxInt(usize));
        } else if (t.isLeader() and p.exited) {
            // The last thread published the exit while this leader was still
            // on its way here; the leader only now becomes collectable, and a
            // parent that looked in between is asleep on the process channel.
            _ = wakeChannelLocked(@intFromPtr(p), std.math.maxInt(usize));
        }
    } else {
        orphanChildrenLocked(t.tid);
    }
    task_count -= 1;
    _ = wakeChannelLocked(@intFromPtr(t), std.math.maxInt(usize));

    const next = pickNext(c);
    next.state = .running;
    c.current = next;

    const top = task_mod_kstack.kstackTop(next);
    gdt.setKernelStack(top);
    percpu.setKernelStack(top);
    address_space.switchTo(null, next.user_space);
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
    gdt.setKernelStack(task_mod_kstack.kstackTop(first));
    percpu.setKernelStack(task_mod_kstack.kstackTop(first));
    address_space.switchTo(null, first.user_space);
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

    gdt.setKernelStack(task_mod_kstack.kstackTop(first));
    percpu.setKernelStack(task_mod_kstack.kstackTop(first));
    address_space.switchTo(null, first.user_space);
    fsbase.set(first.fs_base);
    context.contextStart(first.rsp, &first.fpu);
    unreachable;
}

/// Safe to call with interrupts enabled (see percpu.currentTask).
pub fn currentTask() ?*Task {
    const p = percpu.currentTask() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The user program the running thread belongs to; null for kernel tasks.
pub fn currentProcess() ?*task_mod.Process {
    const t = currentTask() orelse return null;
    return t.process;
}

/// Transfer a live reference to the current kernel task before entering user
/// code. IRQ masking makes the pointer, CR3 and CPU-residency change indivisible
/// to this CPU's scheduler. No user thread-creation API is exposed here.
pub fn attachCurrentUserSpace(space: *address_space.AddressSpace) void {
    const was = spinlock.interruptsEnabled();
    io.cli();
    const task = currentTask() orelse unreachable;
    std.debug.assert(task.user_space == null);
    address_space.switchTo(null, space);
    task.user_space = space;
    if (was) io.sti();
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

    // A thread of an exiting program never starts a new sleep.
    if (prev.kill_pending) {
        lock.release();
        if (was) io.sti();
        return;
    }

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
    // The kill was published under this lock, so it cannot be missed here.
    if (t.kill_pending) {
        unlinkWaiter(t);
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
    // The kill was published under this lock, so it cannot be missed here.
    if (t.kill_pending) {
        unlinkWaiter(t);
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
