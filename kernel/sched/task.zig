//! Task structures.
//!
//! A Task is one thread of execution: a kernel stack, saved registers, FPU and
//! TLS state, and scheduling bookkeeping. Resources that belong to a whole
//! user program (descriptors, handles, stdio, boot-issued authority and the
//! owner identity used by sockets and devices) live in its Process instead.
//! Every user task currently runs alone in its process; shared-address-space
//! threads additionally require VM locking and TLB shootdown.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const context = @import("../arch/x86_64/context.zig");
const vmm = @import("../mm/vmm.zig");
const handle = @import("../ipc/handle.zig");
const ipc_object = @import("../ipc/object.zig");
const vfs = @import("../fs/vfs/vfs.zig");

/// 32 KiB. The syscall and filesystem paths put several 4 KiB buffers on the
/// kernel stack (a block buffer, an IPC payload), and interrupts nest on top
/// of whatever is already there. 16 KiB was demonstrably too tight.
pub const KSTACK_SIZE: usize = 32 * 1024;

/// Written at the very bottom of every kernel stack. The timer tick checks it,
/// so an overflow becomes an immediate, named panic instead of a wild jump
/// through whatever the corruption happened to overwrite.
pub const STACK_CANARY: u64 = 0x0C0F_FEE0_0DEF_ACED;

pub const NAME_LEN: usize = 32;

pub const Error = error{OutOfMemory};

pub const State = enum(u8) {
    ready,
    running,
    blocked,
    zombie,
};

/// Scheduling levels. Lower number = higher priority.
pub const Priority = enum(u8) {
    realtime = 0, // audio, input, compositor — never demoted
    interactive = 1, // GUI apps, shells
    normal = 2, // default for new threads
    batch = 3, // compilers, indexers

    pub fn quantumMs(self: Priority) u32 {
        return switch (self) {
            .realtime => 1,
            .interactive => 4,
            .normal => 16,
            .batch => 64,
        };
    }

    pub fn lower(self: Priority) Priority {
        return switch (self) {
            .realtime => .realtime, // realtime is never demoted
            .interactive => .normal,
            .normal => .batch,
            .batch => .batch,
        };
    }
};

pub const LEVEL_COUNT: usize = 4;

var next_tid: u32 = 1;

/// Resources shared by every thread of one user program.
///
/// The process id is the tid of its first thread, so a single-threaded
/// program's pid and tid are the same number. Each task record that points
/// here holds one reference, which keeps this object readable by a waiting
/// parent after the program's threads are gone. The resources themselves are
/// released by the last thread to exit, before `exited` is published.
pub const Process = struct {
    pid: u32,
    /// Task records referencing this object, live or awaiting collection.
    refs: u32 = 1,
    /// Threads that have not begun exiting. The one that takes this to zero
    /// releases the process resources.
    live_threads: u32 = 1,
    /// Set under the scheduler lock once every resource has been released, so
    /// a parent never reaps a program whose teardown is still running.
    exited: bool = false,
    /// Set under the scheduler lock when any thread ends the whole program.
    /// No thread can be added afterwards; the first exit code wins.
    exiting: bool = false,
    exit_code: i32 = 0,

    /// When set, fd 0/1/2 route to this PTY's slave end instead of the serial
    /// console. Inherited by programs this one spawns, so a shell started in
    /// a terminal keeps its children in the same terminal.
    pty: ?*ipc_object.Object = null,
    /// Capabilities this process holds. Empty at creation: a process starts
    /// with no authority and receives handles explicitly.
    handles: handle.Table = .{},
    /// Files opened by this process. Ordinary spawn does not inherit them.
    files: @import("../fs/fd.zig").FileTable = .{},
    /// Working directory: a canonical absolute path, guarded by `cwd_lock`.
    cwd_lock: @import("../sync/spinlock.zig").SpinLock = .{},
    cwd: [vfs.MAX_PATH]u8 = [_]u8{'/'} ++ [_]u8{0} ** (vfs.MAX_PATH - 1),
    cwd_len: usize = 1,
    /// Signal dispositions and signals pending for any thread.
    signals: @import("signal.zig").ProcessSignals = .{},
    // Boot-issued authority, never inherited by ordinary spawned programs.
    service_manager: bool = false,
    host_bridge: bool = false,
    host_controls: bool = false,

    pub fn create(pid: u32) Error!*Process {
        const self = heap.create(Process) catch return Error.OutOfMemory;
        self.* = .{ .pid = pid, .files = .{ .owner_pid = pid } };
        return self;
    }

    pub fn retain(self: *Process) void {
        const previous = @atomicRmw(u32, &self.refs, .Add, 1, .monotonic);
        std.debug.assert(previous > 0);
    }

    /// Drop a task record's reference. The final release only frees memory:
    /// the last thread has already returned every resource.
    pub fn release(self: *Process) void {
        const previous = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        std.debug.assert(self.handles.count() == 0 and self.pty == null);
        heap.destroy(self);
    }
};

pub const Task = struct {
    tid: u32,
    /// Owner id (a process id, or a kernel task's tid) that may collect this
    /// task's exit status and release its record. Zero means nobody will: the
    /// orphan reaper collects it.
    parent_tid: u32 = 0,
    name: [NAME_LEN]u8,
    name_len: usize,

    state: State,
    priority: Priority,
    /// Ticks left in this thread's slice. Hitting zero means it used its full
    /// quantum and gets demoted; blocking before then keeps its level.
    quantum_left: u32,

    /// Saved stack pointer. Valid whenever the thread is not running.
    rsp: u64,
    /// User FS base (thread pointer), restored on each CPU before resumption.
    fs_base: u64 = 0,
    /// Kernel-owned, initialized without inheriting the spawning CPU's state.
    fpu: @import("../arch/x86_64/fpu.zig").State = .{},
    kstack_base: u64,
    kstack_size: usize,

    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,

    /// Deadline for a sleeping thread, in monotonic nanoseconds, and the link
    /// through the scheduler's sleeper list. Both are meaningless unless the
    /// thread's state is `.blocked` because it called sleepMs.
    wake_at_ns: u64 = 0,
    sleep_next: ?*Task = null,

    /// Wait-queue membership. `wait_channel` is an arbitrary address that
    /// identifies what the thread is waiting for - a port, a PTY - and
    /// `on_wait_list` says whether it is currently linked, which is what makes
    /// the two-phase wait race-free.
    wait_channel: usize = 0,
    wait_next: ?*Task = null,
    on_wait_list: bool = false,
    /// Linked on a run queue. A task is on at most one, at most once.
    on_run_queue: bool = false,
    /// Set only when a timed wait expired, not when its channel was signalled.
    wait_timed_out: bool = false,

    /// The user program this thread belongs to, with one reference held for
    /// the lifetime of this record. Null for kernel tasks.
    process: ?*Process = null,
    /// Set (under the scheduler lock) when the program is exiting. The thread
    /// leaves at its next return towards user mode or attempt to block.
    kill_pending: bool = false,
    /// Signals: blocked for this thread, pending for it alone, a caught
    /// signal waiting to interrupt what it is blocked in, and its alternate
    /// signal stack.
    sig_blocked: u64 = 0,
    sig_pending: u64 = 0,
    sig_interrupt: bool = false,
    alt_stack: @import("signal.zig").AltStack = .{},
    /// User word cleared and woken when this thread exits, so a joiner can
    /// wait on it and then free the thread's stack. Zero means none.
    exit_word: u64 = 0,
    /// Where a newly created user thread enters ring 3.
    user_entry: u64 = 0,
    user_stack: u64 = 0,
    user_arg: u64 = 0,

    /// One owned reference, detached at exit before this task becomes a zombie.
    /// Null kernel tasks use the kernel PML4. Kernel test workers may borrow a
    /// user address space without belonging to any process.
    user_space: ?*@import("../mm/address_space.zig").AddressSpace = null,

    /// Run-queue link.
    next: ?*Task = null,

    /// Accounting.
    ticks_used: u64 = 0,
    switches: u64 = 0,
    exit_code: i32 = 0,

    pub fn pageTable(self: *const Task) u64 {
        return if (self.user_space) |space| space.pml4 else vmm.kernelPml4();
    }

    /// The identity that owns sockets, devices and children: the process id
    /// for user threads, the tid itself for kernel tasks.
    pub fn ownerId(self: *const Task) u32 {
        return if (self.process) |p| p.pid else self.tid;
    }

    /// Whether this is the thread a parent waits on for the whole program.
    pub fn isLeader(self: *const Task) bool {
        return if (self.process) |p| p.pid == self.tid else true;
    }

    pub fn nameSlice(self: *const Task) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Allocate a task and its kernel stack, and fabricate a stack frame so the
/// first switch into it lands at `trampoline`.
pub fn create(
    name: []const u8,
    entry: *const fn (?*anyopaque) void,
    arg: ?*anyopaque,
    priority: Priority,
    trampoline: u64,
) Error!*Task {
    const task = heap.create(Task) catch return Error.OutOfMemory;

    const pages = KSTACK_SIZE / pmm.PAGE_SIZE;
    const order = pmm.orderFor(pages);
    const stack_phys = pmm.allocOrder(order) catch {
        heap.destroy(task);
        return Error.OutOfMemory;
    };
    const stack_base = pmm.physToVirt(stack_phys);

    task.* = .{
        .tid = @atomicRmw(u32, &next_tid, .Add, 1, .monotonic),
        .name = undefined,
        .name_len = @min(name.len, NAME_LEN),
        .state = .ready,
        .priority = priority,
        .quantum_left = priority.quantumMs(),
        .rsp = context.prepareStack(stack_base + KSTACK_SIZE, trampoline),
        .kstack_base = stack_base,
        .kstack_size = KSTACK_SIZE,
        .entry = entry,
        .arg = arg,
    };
    @memcpy(task.name[0..task.name_len], name[0..task.name_len]);

    const canary: *u64 = @ptrFromInt(stack_base);
    canary.* = STACK_CANARY;

    return task;
}

pub fn destroy(task: *Task) void {
    std.debug.assert(task.user_space == null);
    if (task.process) |p| p.release();
    const pages = task.kstack_size / pmm.PAGE_SIZE;
    const order = pmm.orderFor(pages);
    pmm.freeOrder(pmm.virtToPhys(task.kstack_base), order);
    heap.destroy(task);
}

/// True if this task's kernel stack has been overrun.
pub fn stackIntact(t: *const Task) bool {
    const canary: *const u64 = @ptrFromInt(t.kstack_base);
    return canary.* == STACK_CANARY;
}

/// Top of a task's kernel stack, for TSS.rsp0 when user mode arrives.
pub fn kstackTop(task: *const Task) u64 {
    return task.kstack_base + task.kstack_size;
}
