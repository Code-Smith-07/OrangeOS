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
const fd_mod = @import("../fs/fd.zig");
const spinlock = @import("../sync/spinlock.zig");

pub const Error = error{OutOfMemory} || elf.Error;

/// User stack: 8 MiB of addresses just below the non-canonical boundary,
/// backed as it is touched (as on Linux). The top 64 KiB are present from the
/// start: exec writes the arguments and environment there.
const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_F000;
const USER_STACK_SIZE: usize = 8 * 1024 * 1024;
const USER_STACK_EAGER: usize = 64 * 1024;

/// Bytes of argument and environment strings a program may be started with,
/// and how many strings.
pub const ARG_MAX = 32 * 1024;
pub const MAX_STRINGS = 1024;

/// What a program is started with beyond its path: NUL-terminated argument
/// strings followed by NUL-terminated environment strings, in one block.
pub const Arguments = struct {
    block: []const u8 = "",
    argc: usize = 0,
    envc: usize = 0,
    /// The block is a heap allocation that exec frees once it is on the
    /// new program's stack.
    owned: bool = false,

    pub fn free(self: Arguments) void {
        if (self.owned and self.block.len > 0) heap.free(@constCast(self.block.ptr));
    }
};

/// A descriptor a new program starts with: its number there, and the open
/// file description, whose reference passes to the new program.
pub const Grant = struct { number: i32, desc: *fd_mod.Description };

pub const SpawnOptions = struct {
    arguments: Arguments = .{},
    /// Heap array of grants, owned by the spawn.
    grants: []Grant = &.{},
    /// The program starts with exactly `grants`. Otherwise it gets the
    /// console at 0, 1 and 2 (where no grant is).
    exact_descriptors: bool = false,
    /// Canonical absolute working directory; null inherits the caller's.
    cwd: ?[]const u8 = null,
};

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
///         argc, argv[0..argc], NULL, envp[0..envc], NULL, auxv…, AT_NULL
///         … a copy of the program headers, then the strings at the top
///
/// argc is 16-byte aligned, where a Linux-convention `_start` expects rsp to
/// point; rsp itself is 8 mod 16, as after a CALL. The header copy is what
/// AT_PHDR names: the user linker script does not map the ELF headers, and a
/// C runtime finds its thread-local-storage image through them. With no
/// arguments, argv is just the path.
fn buildInitialStack(pml4: u64, node: *const vfs.Node, loaded: elf.Loaded, path: []const u8, arguments: Arguments) Error!u64 {
    var cursor: u64 = USER_STACK_TOP;
    cursor -= path.len + 1;
    const path_address = cursor;
    writeUser(pml4, path_address, path);
    writeUser(pml4, path_address + path.len, &[_]u8{0});
    cursor -= arguments.block.len;
    const block_address = cursor;
    writeUser(pml4, block_address, arguments.block);

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
    const argc = if (arguments.argc == 0) 1 else arguments.argc;
    // Return slot, argc, argv, NULL, envp, NULL, then the auxiliary vector.
    const count = 2 + argc + 1 + arguments.envc + 1 + auxv.len;
    const words_raw = heap.alloc(count * 8) catch return Error.OutOfMemory;
    defer heap.free(words_raw);
    const words: [*]u64 = @ptrCast(@alignCast(words_raw));
    words[0] = 0;
    words[1] = argc;
    var at: usize = 2;
    if (arguments.argc == 0) {
        words[at] = path_address;
        at += 1;
    }
    // Pointers to each string of the block: arguments, NULL, environment, NULL.
    var offset: usize = 0;
    for ([_]usize{ arguments.argc, arguments.envc }) |strings| {
        for (0..strings) |_| {
            words[at] = block_address + offset;
            at += 1;
            offset = (std.mem.indexOfScalarPos(u8, arguments.block, offset, 0) orelse unreachable) + 1;
        }
        words[at] = 0;
        at += 1;
    }
    @memcpy(words[at .. at + auxv.len], &auxv);
    at += auxv.len;
    std.debug.assert(at == count);
    // Keep argc (words[1]) 16-byte aligned.
    cursor = std.mem.alignBackward(u64, cursor - (count - 1) * 8, 16) - 8;
    writeUser(pml4, cursor, std.mem.sliceAsBytes(words[0..count]));
    return cursor;
}

/// Build an address space from a filesystem node and drop into ring 3.
/// Runs as the body of a kernel thread; never returns. Consumes the node's
/// reference, on failure as well as success.
pub fn execNode(node: *const vfs.Node, path: []const u8, arguments: Arguments) Error!noreturn {
    var held = true;
    defer if (held) vfs.release(node.*);
    var holding_arguments = true;
    defer if (holding_arguments) arguments.free();
    const space = try @import("../mm/address_space.zig").AddressSpace.create();
    errdefer space.release();
    const pml4 = space.pml4;

    const loaded = try elf.loadFromNode(pml4, node);

    // User stack, writable and non-executable.
    @import("../mm/user_vm.zig").mapStack(space, USER_STACK_TOP, USER_STACK_SIZE, USER_STACK_EAGER) catch return Error.OutOfMemory;

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
            USER_STACK_SIZE / 1024,
            USER_STACK_TOP - USER_STACK_SIZE,
        });
        console.info("entering ring 3...", .{});
    }

    // Native OrangeOS entries are `callconv(.c) noreturn` functions: RSP is 8
    // mod 16 with a zero return address (a terminal frame for backtraces and
    // allocator instrumentation). The SysV block above it serves C runtimes.
    const entry_stack = try buildInitialStack(pml4, node, loaded, path, arguments);
    // The image is loaded; the file may now change or disappear, and the
    // arguments are on the new stack.
    held = false;
    vfs.release(node.*);
    holding_arguments = false;
    arguments.free();

    // Record it on the task before loading, so the scheduler restores this
    // address space whenever it switches back to this thread.
    sched.attachCurrentUserSpace(space);
    user.enter(loaded.entry, entry_stack);
}

/// A pending program holds a filesystem node reference, not the ELF contents,
/// the path it was started by (argv[0] when no arguments are given), and
/// what it starts with.
pub const SpawnRequest = struct {
    node: vfs.Node,
    path: [vfs.MAX_PATH]u8,
    path_len: usize,
    options: SpawnOptions,
    cwd: [vfs.MAX_PATH]u8,
    cwd_len: usize,
};

/// Start a program with its stdio bound to a PTY.
pub fn spawnPathWithPty(path: []const u8, pty: *@import("../ipc/object.zig").Object) !u32 {
    return spawnPathInternal(path, pty, .{});
}

/// Resolve a program on disk and start it as a new process. Returns its pid.
/// The caller keeps running; use wait() to synchronise.
pub fn spawnPath(path: []const u8) !u32 {
    return spawnWith(path, .{});
}

/// spawnPath with arguments, environment, descriptors and a working
/// directory. Takes ownership of everything in `options`, on failure too.
pub fn spawnWith(path: []const u8, options: SpawnOptions) !u32 {
    const inherited = if (sched.currentProcess()) |parent| parent.pty else null;
    return spawnPathInternal(path, inherited, options);
}

fn releaseOptions(options: SpawnOptions) void {
    options.arguments.free();
    for (options.grants) |grant| grant.desc.release();
    if (options.grants.len > 0) heap.free(@ptrCast(options.grants.ptr));
}

/// The calling program's working directory.
pub fn currentDirectory(out: *[vfs.MAX_PATH]u8) []const u8 {
    const proc = sched.currentProcess() orelse {
        out[0] = '/';
        return out[0..1];
    };
    const state = spinlock.acquireIrqSave(&proc.cwd_lock);
    defer spinlock.releaseIrqRestore(&proc.cwd_lock, state);
    @memcpy(out[0..proc.cwd_len], proc.cwd[0..proc.cwd_len]);
    return out[0..proc.cwd_len];
}

/// Set the calling program's working directory (already canonical and
/// checked to be a directory).
pub fn setCurrentDirectory(path: []const u8) void {
    const proc = sched.currentProcess() orelse return;
    const state = spinlock.acquireIrqSave(&proc.cwd_lock);
    defer spinlock.releaseIrqRestore(&proc.cwd_lock, state);
    @memcpy(proc.cwd[0..path.len], path);
    proc.cwd_len = path.len;
}

fn spawnPathInternal(path: []const u8, pty: ?*@import("../ipc/object.zig").Object, options: SpawnOptions) !u32 {
    errdefer releaseOptions(options);
    if (!vfs.isMounted()) return error.NotMounted;

    const node = vfs.resolve(path) catch return error.NotFound;
    errdefer vfs.release(node);
    if (node.isDir() or node.size() == 0) return error.BadImage;

    const req = heap.create(SpawnRequest) catch return error.OutOfMemory;
    errdefer heap.destroy(req);
    req.* = .{ .node = node, .path = undefined, .path_len = path.len, .options = options, .cwd = undefined, .cwd_len = 0 };
    @memcpy(req.path[0..path.len], path);
    if (options.cwd) |dir| {
        @memcpy(req.cwd[0..dir.len], dir);
        req.cwd_len = dir.len;
    } else req.cwd_len = currentDirectory(&req.cwd).len;
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
    const options = req.options;
    setCurrentDirectory(req.cwd[0..req.cwd_len]);
    heap.destroy(req);

    // What the program starts with: granted descriptors, then (unless the
    // grants are exact) the console wherever 0-2 are still free.
    const proc = sched.currentProcess() orelse unreachable;
    for (options.grants) |grant| fd_mod.installAt(&proc.files, grant.desc, grant.number, false) catch {};
    if (options.grants.len > 0) heap.free(@ptrCast(options.grants.ptr));
    if (!options.exact_descriptors) fd_mod.installConsole(&proc.files) catch {};

    execNode(&node, path[0..path_len], options.arguments) catch |e| {
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
        vfs.release(node);
        sched.exit(1);
    }
    console.print("[ ok ] loading {s} from disk ({d} bytes)\n", .{ path, node.size() });

    if (sched.currentProcess()) |proc| fd_mod.installConsole(&proc.files) catch {};
    execNode(&node, path, .{}) catch |e| {
        console.err("failed to exec {s}: {s}", .{ path, @errorName(e) });
        sched.exit(1);
    };
}
