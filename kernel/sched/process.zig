//! User process creation.
//!
//! A process is an address space plus a thread running in ring 3. The ELF
//! loader reads segments from CitrusFS into owned user pages on demand.

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const elf = @import("../lib/elf.zig");
const user = @import("../arch/x86_64/user.zig");
const gdt = @import("../arch/x86_64/gdt.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const task_mod = @import("task.zig");
const sched = @import("sched.zig");
const console = @import("../console.zig");
const build_options = @import("build_options");
const vfs = @import("../fs/vfs/vfs.zig");
const heap = @import("../mm/heap.zig");

pub const Error = error{OutOfMemory} || elf.Error;

/// User stack: 64 KiB, placed just below the non-canonical boundary.
const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_F000;
const USER_STACK_PAGES: usize = 16;

/// Build an address space from a filesystem node and drop into ring 3.
/// Runs as the body of a kernel thread; never returns.
pub fn execNode(node: *const vfs.Node) Error!noreturn {
    const space = try @import("../mm/address_space.zig").AddressSpace.create();
    errdefer space.release();
    const pml4 = space.pml4;

    const loaded = try elf.loadFromNode(pml4, node);

    // User stack, mapped writable and non-executable.
    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const va = USER_STACK_TOP - (i + 1) * vmm.PAGE_SIZE;
        _ = vmm.allocAndMap(
            pml4,
            va,
            vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE,
        ) catch return Error.OutOfMemory;
    }

    // Point the CPU at this thread's kernel stack for the transition back.
    // Both matter: the TSS supplies rsp0 on an interrupt from ring 3, and the
    // per-CPU block supplies it on a syscall, which does not switch stacks.
    const t = sched.currentTask() orelse return Error.OutOfMemory;
    const kstack_top = task_mod.kstackTop(t);
    gdt.setKernelStack(kstack_top);
    percpu.setKernelStack(kstack_top);

    // Per-spawn detail is noise once a shell is driving the system. Build with
    // -Dverbose-exec to get it back.
    if (build_options.verbose_exec) {
        console.print("[ ok ] loaded ELF: entry 0x{x}, brk 0x{x}\n", .{ loaded.entry, loaded.brk });
        console.print("[ ok ] user stack: {d} KiB at 0x{x}\n", .{
            USER_STACK_PAGES * vmm.PAGE_SIZE / 1024,
            USER_STACK_TOP - USER_STACK_PAGES * vmm.PAGE_SIZE,
        });
        console.info("entering ring 3...", .{});
    }

    // Record it on the task before loading, so the scheduler restores this
    // address space whenever it switches back to this thread.
    std.debug.assert(t.user_space == null);
    t.user_space = space;
    vmm.loadCr3(pml4);
    // Every OrangeOS entry is `callconv(.c) noreturn`, not a POSIX assembly
    // _start expecting argc/argv. Emulate CALL's 8-byte return slot: RSP must
    // be 8 mod 16 at entry. Allocator instrumentation can read @returnAddress
    // even in an inlined entry function; a bare stack-top points it into the
    // unmapped upper guard page. Zero is a deliberate terminal-frame sentinel.
    const entry_stack = USER_STACK_TOP - @sizeOf(u64);
    @as(*u64, @ptrFromInt(entry_stack)).* = 0;
    user.enter(loaded.entry, entry_stack);
}

/// A pending program holds an immutable filesystem node, not the ELF contents.
pub const SpawnRequest = struct {
    node: vfs.Node,
    host_bridge: bool,
    host_controls: bool,
};

/// Start a program with its stdio bound to a PTY.
pub fn spawnPathWithPty(path: []const u8, pty: *@import("../ipc/object.zig").Object) !u32 {
    return spawnPathInternal(path, pty);
}

/// Resolve a program on disk and start it as a new task. Returns its tid.
/// The caller keeps running; use wait() to synchronise.
pub fn spawnPath(path: []const u8) !u32 {
    const inherited = if (sched.currentTask()) |parent| parent.pty else null;
    return spawnPathInternal(path, inherited);
}

fn spawnPathInternal(path: []const u8, pty: ?*@import("../ipc/object.zig").Object) !u32 {
    if (!vfs.isMounted()) return error.NotMounted;

    const node = vfs.resolve(path) catch return error.NotFound;
    if (node.isDir() or node.size() == 0) return error.BadImage;

    const req = heap.create(SpawnRequest) catch return error.OutOfMemory;
    errdefer heap.destroy(req);
    const parent = sched.currentTask();
    req.* = .{ .node = node, .host_controls = std.mem.eql(u8, path, "/bin/hardware"), .host_bridge = if (parent) |p|
        p.service_manager and std.mem.eql(u8, path, "/bin/host-agent")
    else
        false };

    // Name the task after the last path component, so `ps` is readable.
    var name: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| name = path[i + 1 ..];

    const t = sched.spawnWithPty(name, spawnThread, req, .normal, pty) catch return error.OutOfMemory;

    return t.tid;
}

/// Thread body for a spawned program.
fn spawnThread(arg: ?*anyopaque) void {
    const req: *SpawnRequest = @ptrCast(@alignCast(arg.?));
    const node = req.node;
    sched.currentTask().?.host_bridge = req.host_bridge;
    sched.currentTask().?.host_controls = req.host_controls;
    heap.destroy(req);

    execNode(&node) catch |e| {
        console.err("exec failed: {s}", .{@errorName(e)});
        sched.exit(1);
    };
}

/// Thread body: load /sbin/init off the filesystem and run it.
///
/// The binary is no longer embedded in the kernel image. Keeping it there
/// would have cost about a megabyte of kernel .rodata, and the whole point of
/// having a filesystem is that programs live on it.
pub fn initThread(arg: ?*anyopaque) void {
    _ = arg;
    sched.currentTask().?.service_manager = true;

    const path = "/sbin/init";

    if (!vfs.isMounted()) {
        console.err("cannot start {s}: no filesystem mounted", .{path});
        sched.exit(1);
    }

    const node = vfs.resolve(path) catch |e| {
        console.err("cannot find {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };

    if (node.isDir() or node.size() == 0) {
        console.err("{s} is not a nonempty executable file", .{path});
        sched.exit(1);
    }
    console.print("[ ok ] loading {s} from disk ({d} bytes)\n", .{ path, node.size() });

    execNode(&node) catch |e| {
        console.err("failed to exec {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };
}
