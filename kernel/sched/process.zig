//! User process creation.
//!
//! A process is an address space plus a thread running in ring 3. The ELF
//! loader reads segments from CitrusFS into owned user pages on demand.

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const elf = @import("../lib/elf.zig");
const user = @import("../arch/x86_64/user.zig");
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

// Auxiliary-vector keys (SysV x86-64 ABI).
const AT_NULL = 0;
const AT_PHDR = 3;
const AT_PHENT = 4;
const AT_PHNUM = 5;
const AT_PAGESZ = 6;
const AT_ENTRY = 9;
const AT_UID = 11;
const AT_EUID = 12;
const AT_GID = 13;
const AT_EGID = 14;
const AT_SECURE = 23;
const AT_EXECFN = 31;

/// Copy bytes into a user address space through the HHDM, page by page. The
/// destination pages were just mapped by exec, so every page is present.
fn writeUser(pml4: u64, address: u64, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const va = address + done;
        const phys = vmm.translate(pml4, va).?;
        const chunk = @min(vmm.PAGE_SIZE - (va & (vmm.PAGE_SIZE - 1)), bytes.len - done);
        const dest: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
        @memcpy(dest[0..chunk], bytes[done .. done + chunk]);
        done += chunk;
    }
}

/// Lay out the SysV x86-64 initial process stack, above the zero return slot
/// OrangeOS's native `_start` functions expect, so both kinds of entry work:
///
///   rsp → 0 (terminal return address)
///         argc = 1, argv[0], NULL, (no environment) NULL, auxv…, AT_NULL
///         … a copy of the program headers, then the path string at the top
///
/// argc is 16-byte aligned, where a Linux-convention `_start` expects rsp to
/// point; rsp itself is 8 mod 16, as after a CALL. The header copy is what
/// AT_PHDR names: the user linker script does not map the ELF headers, and a
/// C runtime finds its thread-local-storage image through them.
fn buildInitialStack(pml4: u64, node: *const vfs.Node, loaded: elf.Loaded, path: []const u8) Error!u64 {
    var cursor: u64 = USER_STACK_TOP;
    cursor -= path.len + 1;
    const path_address = cursor;
    writeUser(pml4, path_address, path);
    writeUser(pml4, path_address + path.len, &[_]u8{0});

    var headers_buffer: [2048]u8 = undefined;
    const headers = try elf.readProgramHeaders(node, loaded, &headers_buffer);
    cursor = std.mem.alignBackward(u64, cursor - headers.len, 16);
    const headers_address = cursor;
    writeUser(pml4, headers_address, headers);

    const auxv = [_]u64{
        AT_PHDR,   headers_address,
        AT_PHENT,  loaded.phentsize,
        AT_PHNUM,  loaded.phnum,
        AT_PAGESZ, vmm.PAGE_SIZE,
        AT_ENTRY,  loaded.entry,
        AT_UID,    0,
        AT_EUID,   0,
        AT_GID,    0,
        AT_EGID,   0,
        AT_SECURE, 0,
        AT_EXECFN, path_address,
        AT_NULL,   0,
    };
    // Words below the header copy: return slot, argc, argv[0], argv NULL,
    // envp NULL, then the auxiliary vector.
    const words = [_]u64{ 0, 1, path_address, 0, 0 } ++ auxv;
    // Keep argc (words[1]) 16-byte aligned.
    cursor = std.mem.alignBackward(u64, cursor - (words.len - 1) * 8, 16) - 8;
    writeUser(pml4, cursor, std.mem.sliceAsBytes(&words));
    return cursor;
}

/// Build an address space from a filesystem node and drop into ring 3.
/// Runs as the body of a kernel thread; never returns.
pub fn execNode(node: *const vfs.Node, path: []const u8) Error!noreturn {
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

    // The CPU already points at this thread's kernel stack for the transition
    // back: every switch to a thread loads its stack top into the TSS (rsp0,
    // for interrupts from ring 3) and the per-CPU block (for syscalls). It
    // must not be written here, with interrupts on: a thread preempted and
    // moved between finding "this CPU" and the store would overwrite another
    // CPU's entry stack with its own.

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

    // Native OrangeOS entries are `callconv(.c) noreturn` functions: RSP is 8
    // mod 16 with a zero return address (a terminal frame for backtraces and
    // allocator instrumentation). The SysV block above it serves C runtimes.
    const entry_stack = try buildInitialStack(pml4, node, loaded, path);

    // Record it on the task before loading, so the scheduler restores this
    // address space whenever it switches back to this thread.
    sched.attachCurrentUserSpace(space);
    user.enter(loaded.entry, entry_stack);
}

/// A pending program holds an immutable filesystem node, not the ELF contents,
/// and the path it was started by, which becomes argv[0].
pub const SpawnRequest = struct {
    node: vfs.Node,
    path: [vfs.MAX_PATH]u8,
    path_len: usize,
};

/// Start a program with its stdio bound to a PTY.
pub fn spawnPathWithPty(path: []const u8, pty: *@import("../ipc/object.zig").Object) !u32 {
    return spawnPathInternal(path, pty);
}

/// Resolve a program on disk and start it as a new process. Returns its pid.
/// The caller keeps running; use wait() to synchronise.
pub fn spawnPath(path: []const u8) !u32 {
    const inherited = if (sched.currentProcess()) |parent| parent.pty else null;
    return spawnPathInternal(path, inherited);
}

fn spawnPathInternal(path: []const u8, pty: ?*@import("../ipc/object.zig").Object) !u32 {
    if (!vfs.isMounted()) return error.NotMounted;

    const node = vfs.resolve(path) catch return error.NotFound;
    if (node.isDir() or node.size() == 0) return error.BadImage;

    const req = heap.create(SpawnRequest) catch return error.OutOfMemory;
    errdefer heap.destroy(req);
    req.* = .{ .node = node, .path = undefined, .path_len = path.len };
    @memcpy(req.path[0..path.len], path);
    const service_manager = if (sched.currentProcess()) |p| p.service_manager else false;

    // Name the task after the last path component, so `ps` is readable.
    var name: []const u8 = path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| name = path[i + 1 ..];

    const t = sched.spawnProcess(name, spawnThread, req, .normal, .{
        .pty = pty,
        .host_controls = std.mem.eql(u8, path, "/bin/hardware"),
        .host_bridge = service_manager and std.mem.eql(u8, path, "/bin/host-agent"),
    }) catch return error.OutOfMemory;

    return t.tid;
}

/// Thread body for a spawned program.
fn spawnThread(arg: ?*anyopaque) void {
    const req: *SpawnRequest = @ptrCast(@alignCast(arg.?));
    if (req.path_len > vfs.MAX_PATH) {
        // A freed request: the heap left the freeing caller in its first word.
        const words: *const [4]u64 = @ptrCast(@alignCast(req));
        var line: [160]u8 = undefined;
        console.emergencyWrite(std.fmt.bufPrint(&line, "SPAWN request 0x{x} already freed by 0x{x}; words 0x{x} 0x{x}\n", .{ @intFromPtr(req), words[0], words[1], words[2] }) catch "SPAWN request freed\n");
        @panic("spawn request used after free");
    }
    const node = req.node;
    var path: [vfs.MAX_PATH]u8 = undefined;
    const path_len = req.path_len;
    @memcpy(path[0..path_len], req.path[0..path_len]);
    heap.destroy(req);

    execNode(&node, path[0..path_len]) catch |e| {
        console.err("exec failed: {s}", .{@errorName(e)});
        sched.exit(1);
    };
}

/// Kernel-side start of a thread created by `thread_create`. The scheduler
/// has already loaded the program's CR3, this thread's TLS base and kernel
/// stack. A thread created just before its program began exiting leaves
/// without ever running user code.
fn userThreadEntry(_: ?*anyopaque) void {
    const t = sched.currentTask() orelse unreachable;
    if (sched.killPending()) sched.exit(0);
    user.enterWithArg(t.user_entry, t.user_stack, t.user_arg);
}

/// Create a thread in the calling program. Returns its tid.
pub fn createThread(start: sched.UserThreadStart) !u32 {
    const creator = sched.currentTask() orelse return error.NotUserThread;
    const t = try sched.spawnUserThread(creator, userThreadEntry, start);
    return t.tid;
}

/// Start PID 1. Only this boot-created process holds service-manager
/// authority, which is what lets it grant the host bridge to one agent.
pub fn spawnInit() !*task_mod.Task {
    return sched.spawnProcess("init", initThread, null, .normal, .{ .service_manager = true });
}

/// Thread body: load /sbin/init off the filesystem and run it.
///
/// The binary is no longer embedded in the kernel image. Keeping it there
/// would have cost about a megabyte of kernel .rodata, and the whole point of
/// having a filesystem is that programs live on it.
fn initThread(arg: ?*anyopaque) void {
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

    if (node.isDir() or node.size() == 0) {
        console.err("{s} is not a nonempty executable file", .{path});
        sched.exit(1);
    }
    console.print("[ ok ] loading {s} from disk ({d} bytes)\n", .{ path, node.size() });

    execNode(&node, path) catch |e| {
        console.err("failed to exec {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };
}
