//! User process creation.
//!
//! A process is an address space plus a thread running in ring 3. Phase 4b
//! creates one directly from an embedded ELF image; Phase 5 will load them
//! from a filesystem and Phase 6 adds fork/exec.

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

/// Build an address space from an ELF image and drop into ring 3.
/// Runs as the body of a kernel thread; never returns.
pub fn execImage(image: []const u8) Error!noreturn {
    const pml4 = try vmm.createAddressSpace();

    const loaded = try elf.load(pml4, image);

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
    t.address_space = pml4;
    vmm.loadCr3(pml4);
    user.enter(loaded.entry, USER_STACK_TOP);
}

/// A pending program: the image is read in the spawning process's context and
/// handed to the new thread, which loads and enters it.
pub const SpawnRequest = struct {
    image: []u8,
};

/// Start a program with its stdio bound to a PTY.
pub fn spawnPathWithPty(path: []const u8, pty: *anyopaque) !u32 {
    const tid = try spawnPath(path);
    if (sched.findByTid(tid)) |t| t.pty = pty;
    return tid;
}

/// Read a program off disk and start it as a new task. Returns its tid.
/// The caller keeps running; use wait() to synchronise.
pub fn spawnPath(path: []const u8) !u32 {
    if (!vfs.isMounted()) return error.NotMounted;

    const node = vfs.resolve(path) catch return error.NotFound;
    const size: usize = @intCast(node.size());
    if (size == 0 or size > 8 * 1024 * 1024) return error.BadImage;

    const buf = heap.alloc(size) catch return error.OutOfMemory;
    errdefer heap.free(buf);

    const n = vfs.readAt(&node, 0, buf[0..size]) catch return error.IoError;
    if (n != size) return error.IoError;

    const req = heap.create(SpawnRequest) catch return error.OutOfMemory;
    req.* = .{ .image = buf[0..size] };

    // Name the task after the last path component, so `ps` is readable.
    var name: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| name = path[i + 1 ..];

    const t = sched.spawn(name, spawnThread, req, .normal) catch return error.OutOfMemory;

    // Children inherit the terminal they were started from, so a program run
    // from a shell in a window has its output land in that same window.
    if (sched.currentTask()) |parent| t.pty = parent.pty;

    return t.tid;
}

/// Thread body for a spawned program.
fn spawnThread(arg: ?*anyopaque) void {
    const req: *SpawnRequest = @ptrCast(@alignCast(arg.?));
    const image = req.image;
    heap.destroy(req);

    execImage(image) catch |e| {
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

    const path = "/sbin/init";

    if (!vfs.isMounted()) {
        console.err("cannot start {s}: no filesystem mounted", .{path});
        sched.exit(1);
    }

    const node = vfs.resolve(path) catch |e| {
        console.err("cannot find {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };

    const size: usize = @intCast(node.size());
    if (size == 0 or size > 8 * 1024 * 1024) {
        console.err("{s} has an implausible size: {d} bytes", .{ path, size });
        sched.exit(1);
    }

    const buf = heap.alloc(size) catch {
        console.err("out of memory loading {s} ({d} bytes)", .{ path, size });
        sched.exit(1);
    };
    defer heap.free(buf);

    const n = vfs.readAt(&node, 0, buf[0..size]) catch |e| {
        console.err("read {s} failed: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };
    if (n != size) {
        console.err("short read on {s}: {d} of {d} bytes", .{ path, n, size });
        sched.exit(1);
    }

    console.print("[ ok ] loaded {s} from disk ({d} bytes)\n", .{ path, n });

    execImage(buf[0..size]) catch |e| {
        console.err("failed to exec {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };
}
