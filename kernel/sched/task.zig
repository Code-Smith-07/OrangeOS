//! Task structures.
//!
//! Phase 4 stage 1 covers kernel threads only: one address space, no user
//! mode. Process and address-space fields arrive with ring 3.

const std = @import("std");
const heap = @import("../mm/heap.zig");
const pmm = @import("../mm/pmm.zig");
const context = @import("../arch/x86_64/context.zig");
const vmm = @import("../mm/vmm.zig");
const handle = @import("../ipc/handle.zig");

/// 32 KiB. The syscall and filesystem paths put several 4 KiB buffers on the
/// kernel stack (a block buffer, an IPC payload), and interrupts nest on top
/// of whatever is already there. 16 KiB was demonstrably too tight.
pub const KSTACK_SIZE: usize = 32 * 1024;

/// Written at the very bottom of every kernel stack. The timer tick checks it,
/// so an overflow becomes an immediate, named panic instead of a wild jump
/// through whatever the corruption happened to overwrite.
pub const STACK_CANARY: u64 = 0x0C0F_FEE0_0DEF_ACED;

/// Where shared-memory mappings land in a process's address space. Well clear
/// of the program image, the heap, and the stack.
pub const SHM_REGION_BASE: u64 = 0x0000_6000_0000_0000;
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

pub const Task = struct {
    tid: u32,
    name: [NAME_LEN]u8,
    name_len: usize,

    state: State,
    priority: Priority,
    /// Ticks left in this thread's slice. Hitting zero means it used its full
    /// quantum and gets demoted; blocking before then keeps its level.
    quantum_left: u32,

    /// Saved stack pointer. Valid whenever the thread is not running.
    rsp: u64,
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

    /// When set, fd 0/1/2 route to this PTY's slave end instead of the serial
    /// console. Inherited by anything this task spawns, so a shell started in
    /// a terminal keeps its children in the same terminal.
    pty: ?*anyopaque = null,

    /// Capabilities this task holds. Empty at creation: a process starts with
    /// no authority and receives handles explicitly.
    handles: handle.Table = .{},

    /// Next free virtual address for shared-memory mappings. Grows upward
    /// through a region reserved for the purpose.
    shm_next: u64 = SHM_REGION_BASE,

    /// Physical address of this task's PML4. Kernel threads share the kernel's.
    /// The scheduler reloads CR3 on any switch that changes it — without that,
    /// a thread resumes on whatever address space ran last, which presents as
    /// a user process faulting on its own perfectly valid code.
    address_space: u64 = 0,

    /// Run-queue link.
    next: ?*Task = null,

    /// Accounting.
    ticks_used: u64 = 0,
    switches: u64 = 0,
    exit_code: i32 = 0,

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
        .tid = next_tid,
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
        .address_space = vmm.kernelPml4(),
    };
    next_tid += 1;

    @memcpy(task.name[0..task.name_len], name[0..task.name_len]);

    const canary: *u64 = @ptrFromInt(stack_base);
    canary.* = STACK_CANARY;

    return task;
}

pub fn destroy(task: *Task) void {
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
