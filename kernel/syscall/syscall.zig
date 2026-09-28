//! Syscall dispatch.
//!
//! The frame layout below must match kernel/arch/x86_64/syscall_entry.zig
//! exactly — the assembly builds it by hand and this struct reads it.

const std = @import("std");
const console = @import("../console.zig");
const sched = @import("../sched/sched.zig");
const validate = @import("validate.zig");
const vmm = @import("../mm/vmm.zig");
const vfs = @import("../fs/vfs/vfs.zig");
const fd_mod = @import("../fs/fd.zig");
const tmpfs = @import("../fs/tmpfs/tmpfs.zig");
const record_lock = @import("../fs/lock.zig");
const epoll = @import("../ipc/epoll.zig");
const signal = @import("../sched/signal.zig");
const unix_socket = @import("../ipc/unix_socket.zig");
const heap = @import("../mm/heap.zig");
const serial = @import("../drivers/char/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const process = @import("../sched/process.zig");
const pmm = @import("../mm/pmm.zig");
const citrusfs = @import("../fs/citrusfs/citrusfs.zig");
const ipc = @import("../ipc/ipc.zig");
const pty_mod = @import("../ipc/pty.zig");
const ipc_object = @import("../ipc/object.zig");
const net = @import("../net/net.zig");
const event = @import("../drivers/input/event.zig");
const framebuffer = @import("../drivers/video/framebuffer.zig");
const fbcon = @import("../drivers/video/fbcon.zig");
const task_mod = @import("../sched/task.zig");

/// Register state at the syscall boundary. Field order is the reverse of the
/// push order in syscallEntry.
pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Pushed by the entry stub to mirror an interrupt frame.
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Numbers follow the ABI table in ARCHITECTURE.md section 11.2. Once a
/// number is assigned it is stable and is never reused for anything else.
pub const Nr = enum(u64) {
    exit = 0,
    write = 1,
    getpid = 4,
    getppid = 5,
    yield = 7,
    spawn = 8,
    wait = 9,
    mmap = 10,
    munmap = 11,
    mprotect = 12,
    vm_reserve = 13,
    vm_commit = 14,
    vm_decommit = 15,
    tls_set_base = 16,
    tls_get_base = 17,
    user_wait = 18,
    user_wake = 19,
    thread_create = 40,
    thread_exit = 41,
    gettid = 45,
    set_exit_word = 46,
    seek = 24,
    stat = 25,
    fstat = 26,
    clock_ns = 63,
    sleep_ms = 61,
    open = 20,
    close = 21,
    read = 22,
    mkdir = 30,
    rmdir = 31,
    unlink = 32,
    rename = 33,
    ftruncate = 120,
    readdir_fd = 121,
    statfs = 122,
    pread = 123,
    pwrite = 124,
    pipe = 130,
    dup = 131,
    fd_control = 132,
    eventfd = 133,
    epoll_create = 134,
    epoll_ctl = 135,
    epoll_wait = 136,
    poll = 137,
    socketpair = 138,
    sendmsg = 139,
    recvmsg = 140,
    shutdown = 141,
    chdir = 35,
    getcwd = 36,
    resolve_path = 142,
    spawn_process = 143,
    vm_map = 144,
    vm_advise = 145,
    vm_remap = 146,
    memfd = 147,
    getrandom = 148,
    sigaction = 150,
    sigmask = 151,
    kill = 152,
    tkill = 153,
    sigreturn = 154,
    sigaltstack = 155,
    sigpending = 156,
    readdir = 34,
    readdir_page = 38,
    port_create = 50,
    port_connect = 51,
    port_send = 52,
    port_recv = 53,
    shm_create = 54,
    shm_open = 57,
    pty_create = 80,
    pty_read = 81,
    pty_write = 82,
    spawn_pty = 83,
    net_ping = 90,
    net_info = 91,
    net_resolve = 92,
    udp_open = 93,
    udp_send = 94,
    udp_recv = 95,
    udp_close = 96,
    tcp_connect = 97,
    tcp_send = 98,
    tcp_recv = 99,
    tcp_close = 100,
    host_io = 110,
    host_snapshot = 111,
    host_command = 112,
    shm_map = 55,
    handle_close = 56,
    fb_acquire = 70,
    fb_map = 71,
    input_read = 72,
    input_bind = 73,
    input_wait = 74,
    uptime = 60,
    wall_time = 62,
    _,
};

/// Negative return values are -errno, matching the ABI documented in
/// ARCHITECTURE.md §11.
const EFAULT: i64 = -14;
const ENOSYS: i64 = -38;
const EBADF: i64 = -9;
const ENOENT: i64 = -2;
const EMFILE: i64 = -24;
const EISDIR: i64 = -21;
const ENAMETOOLONG: i64 = -36;
const EIO: i64 = -5;
const ENOTDIR: i64 = -20;
const EROFS: i64 = -30;
const ENOTEMPTY: i64 = -39;
const ENOSPC: i64 = -28;
const EXDEV: i64 = -18;
const EFBIG: i64 = -27;
const EBUSY: i64 = -16;
const ESPIPE: i64 = -29;
const EPIPE: i64 = -32;
const EACCES: i64 = -13;
const ENODEV: i64 = -19;
const ENOTSOCK: i64 = -88;
const EPERM: i64 = -1;
const ENOMEM: i64 = -12;
/// The calling program is exiting; a blocked call gave up.
const EINTR: i64 = -4;

var syscall_count: u64 = 0;

/// The single entry point from assembly. Returns 1 when the saved registers
/// must all be restored (the return goes through IRETQ), 0 for SYSRET.
export fn syscallDispatch(frame: *SyscallFrame) callconv(.c) u64 {
    syscall_count += 1;

    // sigreturn replaces every saved register, rax included.
    if (frame.rax == @intFromEnum(Nr.sigreturn)) {
        const t = sched.currentTask() orelse sched.exit(1);
        if (!signal.restore(frame, t, frame.rdi)) sched.exitGroup(128 + signal.SIGSEGV);
        if (sched.killPending()) sched.exit(0);
        _ = signal.deliver(frame);
        return 1;
    }

    // Arguments: rdi, rsi, rdx, r10, r8, r9. Note r10, not rcx — the syscall
    // instruction clobbers rcx with the return address.
    const result: i64 = switch (@as(Nr, @enumFromInt(frame.rax))) {
        .exit => sysExit(@bitCast(frame.rdi)),
        .write => sysWrite(frame.rdi, frame.rsi, frame.rdx),
        .getpid => sysGetpid(),
        .getppid => @intCast(sched.parentOfCurrent()),
        .open => sysOpen(frame.rdi, frame.rsi, frame.rdx),
        .mkdir => sysMkdir(frame.rdi, frame.rsi),
        .rmdir => sysRemove(frame.rdi, frame.rsi, true),
        .unlink => sysRemove(frame.rdi, frame.rsi, false),
        .rename => sysRename(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .ftruncate => sysFtruncate(frame.rdi, frame.rsi),
        .readdir_fd => sysReaddirFd(frame.rdi, frame.rsi, frame.rdx),
        .statfs => sysStatfs(frame.rdi, frame.rsi, frame.rdx),
        .pread => sysPread(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .pwrite => sysPwrite(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .pipe => sysPipe(frame.rdi, frame.rsi),
        .dup => sysDup(frame.rdi, frame.rsi, frame.rdx),
        .fd_control => sysFdControl(frame.rdi, frame.rsi, frame.rdx),
        .eventfd => sysEventFd(frame.rdi, frame.rsi),
        .epoll_create => sysEpollCreate(frame.rdi),
        .epoll_ctl => sysEpollCtl(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .epoll_wait => sysEpollWait(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .poll => sysPoll(frame.rdi, frame.rsi, frame.rdx),
        .socketpair => sysSocketPair(frame.rdi, frame.rsi, frame.rdx),
        .sendmsg => sysSendMsg(frame.rdi, frame.rsi, frame.rdx),
        .recvmsg => sysRecvMsg(frame.rdi, frame.rsi, frame.rdx),
        .shutdown => sysShutdown(frame.rdi, frame.rsi),
        .chdir => sysChdir(frame.rdi, frame.rsi),
        .getcwd => sysGetcwd(frame.rdi, frame.rsi),
        .resolve_path => sysResolvePath(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8),
        .spawn_process => sysSpawnProcess(frame.rdi),
        .vm_map => sysVmMap(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9),
        .vm_advise => sysVmAdvise(frame.rdi, frame.rsi, frame.rdx),
        .vm_remap => sysVmRemap(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .memfd => sysMemfd(frame.rdi),
        .getrandom => sysGetrandom(frame.rdi, frame.rsi, frame.rdx),
        .sigaction => sysSigaction(frame.rdi, frame.rsi, frame.rdx),
        .sigmask => sysSigmask(frame.rdi, frame.rsi, frame.rdx),
        .kill => sysKill(frame.rdi, frame.rsi),
        .tkill => sysTkill(frame.rdi, frame.rsi),
        .sigreturn => unreachable, // handled before the switch
        .sigaltstack => sysSigaltstack(frame.rdi, frame.rsi),
        .sigpending => sysSigpending(frame.rdi),
        .close => sysClose(frame.rdi),
        .read => sysRead(frame.rdi, frame.rsi, frame.rdx),
        .spawn => sysSpawn(frame.rdi, frame.rsi),
        .wait => sysWait(frame.rdi, frame.rsi),
        .mmap => sysMmap(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8, frame.r9),
        .munmap => sysMunmap(frame.rdi, frame.rsi),
        .mprotect => sysMprotect(frame.rdi, frame.rsi, frame.rdx),
        .vm_reserve => sysVmReserve(frame.rdi),
        .vm_commit => sysVmCommit(frame.rdi, frame.rsi, frame.rdx),
        .vm_decommit => sysVmDecommit(frame.rdi, frame.rsi),
        .tls_set_base => sysTlsSetBase(frame.rdi),
        .tls_get_base => sysTlsGetBase(),
        .user_wait => sysUserWait(frame.rdi, frame.rsi, frame.rdx),
        .user_wake => sysUserWake(frame.rdi, frame.rsi),
        .thread_create => sysThreadCreate(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8),
        .thread_exit => sysThreadExit(@bitCast(frame.rdi)),
        .gettid => sysGettid(),
        .set_exit_word => sysSetExitWord(frame.rdi),
        .seek => sysSeek(frame.rdi, frame.rsi, frame.rdx),
        .stat => sysStat(frame.rdi, frame.rsi, frame.rdx),
        .fstat => sysFstat(frame.rdi, frame.rsi),
        .clock_ns => sysClockNs(frame.rdi),
        .sleep_ms => sysSleepMs(frame.rdi),
        // Fourth argument is in r10, not rcx: the syscall instruction
        // clobbers rcx with the return address.
        .readdir => sysReaddir(frame.rdi, frame.rsi, frame.rdx, frame.r10, 0),
        .readdir_page => sysReaddir(frame.rdi, frame.rsi, frame.rdx, frame.r10, frame.r8),
        .port_create => sysPortCreate(frame.rdi, frame.rsi),
        .port_connect => sysPortConnect(frame.rdi, frame.rsi),
        .port_send => sysPortSend(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .port_recv => sysPortRecv(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .shm_create => sysShmCreate(frame.rdi, frame.rsi, frame.rdx),
        .shm_open => sysShmOpen(frame.rdi, frame.rsi),
        .pty_create => sysPtyCreate(),
        .pty_read => sysPtyRead(frame.rdi, frame.rsi, frame.rdx),
        .pty_write => sysPtyWrite(frame.rdi, frame.rsi, frame.rdx),
        .spawn_pty => sysSpawnPty(frame.rdi, frame.rsi, frame.rdx),
        .net_ping => sysNetPing(frame.rdi, frame.rsi, frame.rdx),
        .net_info => sysNetInfo(frame.rdi),
        .net_resolve => sysNetResolve(frame.rdi, frame.rsi),
        .udp_open => sysUdpOpen(frame.rdi),
        .udp_send => sysUdpSend(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .udp_recv => sysUdpRecv(frame.rdi, frame.rsi, frame.rdx),
        .udp_close => sysUdpClose(frame.rdi),
        .tcp_connect => sysTcpConnect(frame.rdi, frame.rsi, frame.rdx),
        .tcp_send => sysTcpSend(frame.rdi, frame.rsi, frame.rdx),
        .tcp_recv => sysTcpRecv(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .tcp_close => sysTcpClose(frame.rdi),
        .host_io => sysHostIo(frame.rdi, frame.rsi, frame.rdx),
        .host_snapshot => sysHostSnapshot(frame.rdi, frame.rsi, frame.rdx),
        .host_command => @import("host_command.zig").operation(frame.rdi, frame.rsi, frame.rdx),
        .shm_map => sysShmMap(frame.rdi, frame.rsi),
        .handle_close => sysHandleClose(frame.rdi),
        .fb_acquire => sysFbAcquire(frame.rdi),
        .fb_map => sysFbMap(),
        .input_read => sysInputRead(frame.rdi, frame.rsi),
        .input_bind => sysInputBind(frame.rdi),
        .input_wait => sysInputWait(frame.rdi),
        .yield => sysYield(),
        .uptime => sysUptime(),
        .wall_time => if (@import("../time/time.zig").unixSeconds()) |seconds| @intCast(seconds) else -5,
        else => ENOSYS,
    };

    frame.rax = @bitCast(result);
    // A thread of an exiting program never returns to user mode.
    if (sched.killPending()) sched.exit(0);
    // Pending signals are acted on here; a handler means a full restore.
    return @intFromBool(signal.deliver(frame));
}

const snapshot_sync = @import("../sync/spinlock.zig");
const user_vm = @import("../mm/user_vm.zig");
fn vmErrno(e: user_vm.Error) i64 {
    return switch (e) {
        error.Invalid => -22,
        error.Unsupported => -95,
        error.OutOfMemory => -12,
        error.Exists => EEXIST,
    };
}
// Anonymous VM changes may shoot down other CPUs running threads of this
// program, and must keep acknowledging theirs while they wait. SYSCALL masked
// interrupts on entry, so each call re-enables them for the duration.

fn sysMmap(address: u64, len: u64, prot: u64, flags: u64, fd: u64, offset: u64) i64 {
    // MAP_PRIVATE | MAP_ANONYMOUS. No MAP_FIXED, file mappings or hints yet.
    if (address != 0 or flags != 0x22 or fd != std.math.maxInt(u64) or offset != 0) return -95;
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    return @intCast(user_vm.map(space, len, prot) catch |e| return vmErrno(e));
}
fn sysMunmap(address: u64, len: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    user_vm.unmap(space, address, len) catch |e| return vmErrno(e);
    return 0;
}
fn sysMprotect(address: u64, len: u64, prot: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    user_vm.protect(space, address, len, prot) catch |e| return vmErrno(e);
    return 0;
}
/// vm_map flags.
const MAP_FIXED: u64 = 1;
const MAP_FIXED_NOREPLACE: u64 = 2;
const MAP_HINT: u64 = 4;
/// With a descriptor: share the file's pages instead of copying them.
const MAP_SHARED: u64 = 8;

/// Memory in the Linux mmap model: backed as it is touched, with one
/// protection that mprotect can change page range by page range. `address`
/// is a hint (MAP_HINT) or a requirement (MAP_FIXED replaces lazy mappings
/// already there; MAP_FIXED_NOREPLACE fails instead). Anonymous only so far:
/// `fd` must be -1.
fn sysVmMap(address: u64, length: u64, prot: u64, flags: u64, fd: u64, offset: u64) i64 {
    if (flags & ~(MAP_FIXED | MAP_FIXED_NOREPLACE | MAP_HINT | MAP_SHARED) != 0) return EINVAL;
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    // A descriptor: share a tmpfs file's frames (memfd, /tmp), or copy any
    // file's pages privately on first touch.
    var backing: user_vm.Backing = .anonymous;
    if (fd != std.math.maxInt(u64)) {
        if (offset % vmm.PAGE_SIZE != 0) return EINVAL;
        const desc = descriptionOf(fd) orelse return EBADF;
        defer desc.release();
        const file = switch (desc.object) {
            .node => |*f| f,
            else => return ENODEV,
        };
        if (file.node.isDir()) return ENODEV;
        const status = desc.statusFlags();
        if (status & vfs.OPEN_READ == 0) return EACCES;
        const want_write = prot & 2 != 0;
        if (flags & MAP_SHARED != 0 and file.node == .tmp) {
            if (want_write and status & vfs.OPEN_WRITE == 0) return EACCES;
            tmpfs.beginMapping(file.node.tmp, want_write, true) catch return EPERM;
            backing = .{ .shared = .{ .inode = file.node.tmp, .offset = offset } };
        } else {
            // A read-only filesystem cannot share writes.
            if (flags & MAP_SHARED != 0 and want_write) return EACCES;
            const ref = user_vm.FileRef.create(vfs.retain(file.node)) catch {
                vfs.release(file.node);
                return ENOMEM;
            };
            backing = .{ .file = .{ .ref = ref, .offset = offset } };
        }
    } else if (offset != 0 or flags & MAP_SHARED != 0) return EINVAL;
    const placement: user_vm.Placement = if (flags & MAP_FIXED_NOREPLACE != 0)
        .fixed_noreplace
    else if (flags & MAP_FIXED != 0)
        .fixed
    else if (flags & MAP_HINT != 0 and address != 0)
        .hint
    else
        .anywhere;
    io.sti();
    defer io.cli();
    return @intCast(user_vm.mapBacked(space, address, length, prot, placement, backing) catch |e| {
        switch (backing) {
            .anonymous => {},
            .shared => |b| tmpfs.endMapping(b.inode, prot & 2 != 0),
            .file => |b| b.ref.release(),
        }
        return vmErrno(e);
    });
}

// ── Signals ─────────────────────────────────────────────────────────────────

fn sysSigaction(sig: u64, new_ptr: u64, old_ptr: u64) i64 {
    const proc = sched.currentProcess() orelse return EIO;
    if (sig == 0 or sig > signal.COUNT) return EINVAL;
    const pml4 = vmm.currentCr3();
    var new: ?signal.Action = null;
    if (new_ptr != 0) {
        var action: signal.Action = undefined;
        validate.copyFromUser(pml4, std.mem.asBytes(&action), new_ptr, @sizeOf(signal.Action)) catch return EFAULT;
        if (action.handler >= validate.USER_MAX or action.restorer >= validate.USER_MAX) return EFAULT;
        new = action;
    }
    var old: signal.Action = undefined;
    signal.setAction(proc, @intCast(sig), new, &old) catch return EINVAL;
    if (old_ptr != 0) validate.copyToUser(pml4, old_ptr, std.mem.asBytes(&old), @sizeOf(signal.Action)) catch return EFAULT;
    return 0;
}

/// how: 0 block, 1 unblock, 2 set. The old mask is written when asked.
fn sysSigmask(how: u64, set_ptr: u64, old_ptr: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    const pml4 = vmm.currentCr3();
    const old = t.sig_blocked;
    if (set_ptr != 0) {
        var set: u64 = undefined;
        validate.copyFromUser(pml4, std.mem.asBytes(&set), set_ptr, 8) catch return EFAULT;
        const updated = switch (how) {
            0 => old | set,
            1 => old & ~set,
            2 => set,
            else => return EINVAL,
        };
        @atomicStore(u64, &t.sig_blocked, updated & ~signal.UNBLOCKABLE, .release);
    }
    if (old_ptr != 0) validate.copyToUser(pml4, old_ptr, std.mem.asBytes(&old), 8) catch return EFAULT;
    return 0;
}

fn signalErrno(e: sched.SignalError) i64 {
    return switch (e) {
        error.NotFound => -3, // ESRCH
        error.NotPermitted => EPERM,
        error.Invalid => EINVAL,
    };
}

/// kill: a program (pid > 0) the caller may signal: itself or one it
/// started. Process groups (pid <= 0) are not offered.
fn sysKill(pid: u64, sig: u64) i64 {
    const proc = sched.currentProcess() orelse return EIO;
    const target: i64 = @bitCast(pid);
    if (target <= 0 or target > std.math.maxInt(u32)) return EINVAL;
    sched.signalProcess(@intCast(target), @intCast(@min(sig, 1000)), proc) catch |e| return signalErrno(e);
    return 0;
}

/// tkill: a thread of the caller's own program.
fn sysTkill(tid: u64, sig: u64) i64 {
    const proc = sched.currentProcess() orelse return EIO;
    if (tid == 0 or tid > std.math.maxInt(u32)) return EINVAL;
    sched.signalThread(@intCast(tid), @intCast(@min(sig, 1000)), proc) catch |e| return signalErrno(e);
    return 0;
}

/// stack_t: sp, flags (1 on stack, 2 disabled), size.
const StackT = extern struct { sp: u64, flags: i32, pad: i32 = 0, size: u64 };

fn sysSigaltstack(new_ptr: u64, old_ptr: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    const pml4 = vmm.currentCr3();
    const current = t.alt_stack;
    if (old_ptr != 0) {
        const old = StackT{ .sp = current.sp, .flags = if (current.disabled) 2 else 0, .size = current.size };
        validate.copyToUser(pml4, old_ptr, std.mem.asBytes(&old), @sizeOf(StackT)) catch return EFAULT;
    }
    if (new_ptr != 0) {
        var new: StackT = undefined;
        validate.copyFromUser(pml4, std.mem.asBytes(&new), new_ptr, @sizeOf(StackT)) catch return EFAULT;
        if (new.flags & ~@as(i32, 2) != 0) return EINVAL;
        if (new.flags & 2 != 0) {
            t.alt_stack = .{};
        } else {
            if (new.size < 2048) return -12; // ENOMEM: below MINSIGSTKSZ
            if (new.sp >= validate.USER_MAX or new.size > validate.USER_MAX - new.sp) return EFAULT;
            t.alt_stack = .{ .sp = new.sp, .size = new.size, .disabled = false };
        }
    }
    return 0;
}

fn sysSigpending(out: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    const p = t.process orelse return EIO;
    const pending = (@atomicLoad(u64, &t.sig_pending, .acquire) | @atomicLoad(u64, &p.signals.pending, .acquire)) & t.sig_blocked;
    validate.copyToUser(vmm.currentCr3(), out, std.mem.asBytes(&pending), 8) catch return EFAULT;
    return 0;
}

/// getrandom: up to 4096 bytes from the kernel generator per call. Flags: 1
/// do not wait for the first seeding (EAGAIN), 2 use the pool as it stands
/// if not yet seeded.
fn sysGetrandom(buf: u64, len: u64, flags: u64) i64 {
    if (flags & ~@as(u64, 3) != 0) return EINVAL;
    const random = @import("../lib/random.zig");
    const n: usize = @intCast(@min(len, 4096));
    if (n == 0) return 0;
    var kbuf: [4096]u8 = undefined;
    io.sti();
    defer io.cli();
    const wait: random.Wait = if (flags & 2 != 0) .insecure else if (flags & 1 != 0) .fail else .block;
    random.fill(kbuf[0..n], wait) catch |e| return switch (e) {
        error.WouldBlock => EAGAIN,
        error.Interrupted => EINTR,
    };
    validate.copyToUser(vmm.currentCr3(), buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

/// memfd_create: an anonymous tmpfs file. Flags: 2 close-on-exec, 8 allow
/// sealing.
fn sysMemfd(flags: u64) i64 {
    if (flags & ~(FD_CLOEXEC | 8) != 0) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    const inode = tmpfs.createAnonymous(flags & 8 != 0) catch return ENOMEM;
    const desc = fd_mod.Description.create(.{ .node = .{ .node = .{ .tmp = inode } } }, vfs.OPEN_READ | vfs.OPEN_WRITE) catch {
        tmpfs.release(inode);
        return ENOMEM;
    };
    return fd_mod.install(&proc.files, desc, fd_mod.FD_BASE, flags & FD_CLOEXEC != 0) catch |e| {
        desc.release();
        return vfsErrno(e);
    };
}

/// madvise. 4 (DONTNEED) releases the frames of lazily backed pages, which
/// read as zeros when next touched; other advice is accepted and ignored.
fn sysVmAdvise(address: u64, length: u64, advice: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    if (advice != 4) return 0;
    io.sti();
    defer io.cli();
    user_vm.discard(space, address, length) catch |e| return vmErrno(e);
    return 0;
}

/// mremap of lazily backed memory; flag 1 allows moving it.
fn sysVmRemap(address: u64, old_length: u64, new_length: u64, flags: u64) i64 {
    if (flags & ~@as(u64, 1) != 0) return EINVAL;
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    return @intCast(user_vm.remap(space, address, old_length, new_length, flags & 1 != 0) catch |e| return vmErrno(e));
}

fn sysVmReserve(len: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    return @intCast(user_vm.reserve(space, len) catch |e| return vmErrno(e));
}
fn sysVmCommit(address: u64, len: u64, prot: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    user_vm.commit(space, address, len, prot) catch |e| return vmErrno(e);
    return 0;
}
fn sysVmDecommit(address: u64, len: u64) i64 {
    const t = sched.currentTask() orelse return -14;
    const space = t.user_space orelse return -14;
    io.sti();
    defer io.cli();
    user_vm.decommit(space, address, len) catch |e| return vmErrno(e);
    return 0;
}

fn sysTlsSetBase(base: u64) i64 {
    if (base >= validate.USER_MAX) return -22;
    const t = sched.currentTask() orelse return EIO;
    t.fs_base = base;
    @import("../arch/x86_64/fsbase.zig").set(base);
    return 0;
}

fn sysTlsGetBase() i64 {
    const t = sched.currentTask() orelse return EIO;
    return @intCast(t.fs_base);
}

const user_wait = @import("../sync/user_wait.zig");
fn waitErrno(e: user_wait.Error) i64 {
    return switch (e) {
        error.Invalid => -22,
        error.BadAddress => EFAULT,
        error.WouldBlock => -11,
        error.Timeout => -110,
    };
}

fn sysUserWait(address: u64, expected: u64, timeout_ms: u64) i64 {
    if (expected > std.math.maxInt(u32) or timeout_ms > 60_000) return -22;
    const t = sched.currentTask() orelse return EIO;
    user_wait.wait(t.pageTable(), address, @intCast(expected), timeout_ms) catch |e| return waitErrno(e);
    return 0;
}

fn sysUserWake(address: u64, max_wake: u64) i64 {
    if (max_wake > 64) return -22;
    const t = sched.currentTask() orelse return EIO;
    return @intCast(user_wait.wake(t.pageTable(), address, @intCast(max_wake)) catch |e| return waitErrno(e));
}

var snapshot_lock: snapshot_sync.SpinLock = .{};
var host_snapshot: [4096]u8 = undefined;
var snapshot_len: usize = 0;
var snapshot_at: u64 = 0;
fn sysHostSnapshot(op: u64, ptr: u64, len: u64) i64 {
    const task = sched.currentTask() orelse return -13;
    if (op > 1 or len > 4096) return -22;
    if (op == 1 and !hostBridge(task)) return -13;
    var buffer: [4096]u8 = undefined;
    if (op == 1) validate.copyFromUser(task.pageTable(), &buffer, ptr, @intCast(len)) catch return EFAULT;
    const now = @import("../time/time.zig").millisSinceBoot();
    const irq = snapshot_sync.acquireIrqSave(&snapshot_lock);
    if (op == 1) {
        snapshot_len = @intCast(len);
        @memcpy(host_snapshot[0..snapshot_len], buffer[0..snapshot_len]);
        snapshot_at = now;
        snapshot_sync.releaseIrqRestore(&snapshot_lock, irq);
        return @intCast(len);
    }
    if (snapshot_len == 0 or now -| snapshot_at > 6000) {
        snapshot_sync.releaseIrqRestore(&snapshot_lock, irq);
        return -11;
    }
    const size = snapshot_len;
    if (len < size) {
        snapshot_sync.releaseIrqRestore(&snapshot_lock, irq);
        return -22;
    }
    @memcpy(buffer[0..size], host_snapshot[0..size]);
    snapshot_sync.releaseIrqRestore(&snapshot_lock, irq);
    validate.copyToUser(task.pageTable(), ptr, buffer[0..size], size) catch return EFAULT;
    return @intCast(size);
}

fn hostBridge(task: *const task_mod.Task) bool {
    return if (task.process) |p| p.host_bridge else false;
}

fn sysHostIo(op: u64, ptr: u64, len: u64) i64 {
    const task = sched.currentTask() orelse return -13;
    if (!hostBridge(task)) return -13;
    const bridge = @import("../drivers/virtio/serial.zig");
    var buf: [512]u8 = undefined;
    if (op == 2) return if (len == 0) bridge.operation(op, buf[0..0]) else -22;
    if (op > 3 or len == 0 or len > buf.len or (op == 3 and len != 64)) return -22;
    const n: usize = @intCast(len);
    if (op == 1) {
        validate.copyFromUser(task.pageTable(), &buf, ptr, n) catch return EFAULT;
    } else {
        validate.check(task.pageTable(), ptr, n, true) catch return EFAULT;
    }
    const result = bridge.operation(op, buf[0..n]);
    if (result > 0 and op != 1) {
        const copied: usize = @intCast(result);
        validate.copyToUser(task.pageTable(), ptr, buf[0..copied], copied) catch return EFAULT;
    }
    return result;
}

/// End the whole program: every thread, with this status.
fn sysExit(code: i64) i64 {
    sched.exitGroup(@truncate(code));
}

fn isUserAddress(value: u64) bool {
    return value >= 0x1000 and value < validate.USER_MAX;
}

/// Start a thread in the calling program: `entry(arg)` on `stack`, with
/// `tls` as its FS base. A nonzero `exit_word` must be a writable, aligned
/// u32; the kernel stores 0 there and wakes it when the thread exits, which
/// is what a joiner waits for before freeing the stack.
fn sysThreadCreate(entry: u64, stack: u64, arg: u64, tls: u64, exit_word: u64) i64 {
    if (!isUserAddress(entry) or !isUserAddress(stack) or stack % 8 != 0) return EINVAL;
    if (tls >= validate.USER_MAX) return EINVAL;
    if (exit_word != 0) {
        if (exit_word % 4 != 0) return EINVAL;
        validate.check(vmm.currentCr3(), exit_word, 4, true) catch return EFAULT;
    }
    const tid = process.createThread(.{
        .entry = entry,
        .stack = stack,
        .arg = arg,
        .fs_base = tls,
        .exit_word = exit_word,
    }) catch |e| return switch (e) {
        error.ProcessExiting => EINTR,
        error.OutOfMemory => EAGAIN,
        error.NotUserThread => EIO,
    };
    return @intCast(tid);
}

/// End only the calling thread. The program continues while it has others.
fn sysThreadExit(code: i64) i64 {
    const t = sched.currentTask() orelse return EIO;
    if (t.exit_word != 0) {
        // After this store the thread never touches its user stack again, so
        // a woken joiner may unmap it at once. A word the program already
        // unmapped is ignored.
        _ = user_wait.storeAndWake(t.pageTable(), t.exit_word, 0, 64) catch 0;
    }
    sched.exit(@truncate(code));
}

fn sysGettid() i64 {
    const t = sched.currentTask() orelse return EIO;
    return @intCast(t.tid);
}

/// Change the word cleared and woken when the calling thread exits (0 for
/// none), as C runtimes' set_tid_address does. Returns the caller's tid.
fn sysSetExitWord(address: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    if (address != 0 and (address % 4 != 0 or !isUserAddress(address))) return EINVAL;
    t.exit_word = address;
    return @intCast(t.tid);
}

/// What `stat`/`fstat` report. Kinds: 1 regular file, 2 directory, 3 the
/// console or a terminal (descriptors 0-2). `fstat` also reports the
/// descriptor's access mode (vfs.OPEN_READ/WRITE/APPEND); `stat` reports
/// whether the file's filesystem is writable (vfs.OPEN_WRITE).
const FileStatus = extern struct {
    size: u64,
    kind: u32,
    mode: u32 = 0,
};

fn copyStatus(pointer: u64, status: FileStatus) i64 {
    validate.copyToUser(vmm.currentCr3(), pointer, std.mem.asBytes(&status), @sizeOf(FileStatus)) catch return EFAULT;
    return 0;
}

/// The open file description behind `fd`, with a reference for the caller;
/// null when there is none (for 0-2, the console).
fn descriptionOf(fd: u64) ?*fd_mod.Description {
    if (fd > std.math.maxInt(i32)) return null;
    const proc = sched.currentProcess() orelse return null;
    return fd_mod.lookup(&proc.files, @intCast(fd));
}

fn sysSeek(fd: u64, offset: u64, whence: u64) i64 {
    if (whence > 2) return EINVAL;
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    const position = fd_mod.seek(desc, @bitCast(offset), @enumFromInt(whence)) catch |e| return vfsErrno(e);
    return @intCast(position);
}

fn sysStat(path_ptr: u64, path_len: u64, out: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    const node = vfs.resolve(name) catch |e| return vfsErrno(e);
    defer vfs.release(node);
    return copyStatus(out, .{
        .size = node.size(),
        .kind = if (node.isDir()) 2 else if (node == .device) 7 else 1,
        .mode = if (node.writable()) vfs.OPEN_READ | vfs.OPEN_WRITE else vfs.OPEN_READ,
    });
}

fn sysFstat(fd: u64, out: u64) i64 {
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    const status = fd_mod.stat(desc);
    return copyStatus(out, .{ .size = status.size, .kind = @intFromEnum(status.kind), .mode = status.mode });
}

/// Nanoseconds on clock 0 (monotonic, since boot) or 1 (wall, since the
/// Unix epoch).
fn sysClockNs(clock: u64) i64 {
    const time = @import("../time/time.zig");
    return switch (clock) {
        0 => @intCast(time.monotonicNs()),
        1 => if (time.unixNanos()) |ns| @intCast(ns) else EIO,
        else => EINVAL,
    };
}

fn sysWrite(fd: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;
    var kbuf: [4096]u8 = undefined;
    validate.copyFromUser(vmm.currentCr3(), &kbuf, buf, @intCast(len)) catch return EFAULT;
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    // A pipe, socket or eventfd write may block until a reader makes room.
    io.sti();
    defer io.cli();
    const n = fd_mod.write(desc, kbuf[0..@intCast(len)]) catch |e| return vfsErrno(e);
    return @intCast(n);
}

/// Map a VFS error onto the ABI's errno values.
fn vfsErrno(e: vfs.Error) i64 {
    return switch (e) {
        vfs.Error.NotFound, vfs.Error.NotMounted => ENOENT,
        vfs.Error.NotDirectory => ENOTDIR,
        vfs.Error.NotFile, vfs.Error.IsDirectory => EISDIR,
        vfs.Error.ReadOnly => EROFS,
        vfs.Error.Exists => EEXIST,
        vfs.Error.NotEmpty => ENOTEMPTY,
        vfs.Error.NoSpace => ENOSPC,
        vfs.Error.CrossDevice => EXDEV,
        vfs.Error.InvalidArgument => EINVAL,
        vfs.Error.FileTooBig => EFBIG,
        vfs.Error.Busy => EBUSY,
        vfs.Error.WouldBlock => EAGAIN,
        vfs.Error.BrokenPipe => EPIPE,
        vfs.Error.Interrupted => EINTR,
        vfs.Error.NotSeekable => ESPIPE,
        vfs.Error.OutOfMemory => ENOMEM,
        vfs.Error.MessageTooLong => EMSGSIZE,
        vfs.Error.NotPermitted => EPERM,
        vfs.Error.NameTooLong => ENAMETOOLONG,
        vfs.Error.TooManyOpen => EMFILE,
        vfs.Error.BadFd => EBADF,
        vfs.Error.IoError => EIO,
    };
}

fn sysOpen(path_ptr: u64, path_len: u64, flags: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    if (flags > std.math.maxInt(u32)) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    const fd = fd_mod.open(&proc.files, name, @intCast(flags)) catch |e| return vfsErrno(e);
    return fd;
}

/// Copy a user path into `buffer` as a canonical absolute path: a relative
/// path is taken from the program's working directory.
fn copyPath(buffer: *[vfs.MAX_PATH]u8, pointer: u64, len: u64) error{ ENAMETOOLONG, EFAULT }![]const u8 {
    if (len == 0 or len > vfs.MAX_PATH) return error.ENAMETOOLONG;
    var raw: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(vmm.currentCr3(), &raw, pointer, @intCast(len)) catch return error.EFAULT;
    return absolutePath(null, raw[0..@intCast(len)], buffer) catch error.ENAMETOOLONG;
}

/// `path` made absolute against a directory (a canonical path) or, by
/// default, the working directory, then normalized into `out`.
fn absolutePath(base: ?[]const u8, path: []const u8, out: *[vfs.MAX_PATH]u8) vfs.Error![]const u8 {
    if (path.len > 0 and path[0] == '/') return vfs.normalize(path, out);
    var joined: [2 * vfs.MAX_PATH + 1]u8 = undefined;
    var cwd: [vfs.MAX_PATH]u8 = undefined;
    const dir = base orelse process.currentDirectory(&cwd);
    @memcpy(joined[0..dir.len], dir);
    joined[dir.len] = '/';
    @memcpy(joined[dir.len + 1 .. dir.len + 1 + path.len], path);
    return vfs.normalize(joined[0 .. dir.len + 1 + path.len], out);
}

fn pathErrno(e: error{ ENAMETOOLONG, EFAULT }) i64 {
    return switch (e) {
        error.ENAMETOOLONG => ENAMETOOLONG,
        error.EFAULT => EFAULT,
    };
}

fn sysMkdir(path_ptr: u64, path_len: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    vfs.mkdir(name) catch |e| return vfsErrno(e);
    return 0;
}

fn sysRemove(path_ptr: u64, path_len: u64, directory: bool) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    vfs.remove(name, directory) catch |e| return vfsErrno(e);
    return 0;
}

fn sysRename(from_ptr: u64, from_len: u64, to_ptr: u64, to_len: u64) i64 {
    var from: [vfs.MAX_PATH]u8 = undefined;
    var to: [vfs.MAX_PATH]u8 = undefined;
    const source = copyPath(&from, from_ptr, from_len) catch |e| return pathErrno(e);
    const target = copyPath(&to, to_ptr, to_len) catch |e| return pathErrno(e);
    vfs.rename(source, target) catch |e| return vfsErrno(e);
    return 0;
}

fn sysPread(fd: u64, buf: u64, len: u64, offset: u64) i64 {
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;
    if (offset > std.math.maxInt(i64)) return EINVAL;
    var kbuf: [4096]u8 = undefined;
    const n = fd_mod.readAtOffset(desc, offset, kbuf[0..@intCast(len)]) catch |e| return vfsErrno(e);
    validate.copyToUser(vmm.currentCr3(), buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

fn sysPwrite(fd: u64, buf: u64, len: u64, offset: u64) i64 {
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;
    if (offset > std.math.maxInt(i64)) return EINVAL;
    var kbuf: [4096]u8 = undefined;
    validate.copyFromUser(vmm.currentCr3(), &kbuf, buf, @intCast(len)) catch return EFAULT;
    const n = fd_mod.writeAtOffset(desc, offset, kbuf[0..@intCast(len)]) catch |e| return vfsErrno(e);
    return @intCast(n);
}

fn sysFtruncate(fd: u64, length: u64) i64 {
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    if (length > std.math.maxInt(i64)) return EINVAL;
    fd_mod.truncate(desc, length) catch |e| return vfsErrno(e);
    return 0;
}

// ── Pipes, duplication, descriptor flags, eventfd ───────────────────────────

/// Flags for pipe, dup and eventfd.
const FD_NONBLOCK: u64 = 1;
const FD_CLOEXEC: u64 = 2;
const EFD_SEMAPHORE: u64 = 4;

fn sysPipe(out: u64, flags: u64) i64 {
    if (flags & ~(FD_NONBLOCK | FD_CLOEXEC) != 0) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    const fds = fd_mod.createPipe(&proc.files, flags & FD_NONBLOCK != 0, flags & FD_CLOEXEC != 0) catch |e| return vfsErrno(e);
    validate.copyToUser(vmm.currentCr3(), out, std.mem.asBytes(&fds), @sizeOf([2]i32)) catch {
        fd_mod.close(&proc.files, fds[0]) catch {};
        fd_mod.close(&proc.files, fds[1]) catch {};
        return EFAULT;
    };
    return 0;
}

/// dup (`new` = -1: the lowest free descriptor) or dup2/dup3 (exactly `new`).
fn sysDup(old: u64, new: u64, flags: u64) i64 {
    if (flags & ~FD_CLOEXEC != 0) return EINVAL;
    if (old > std.math.maxInt(i32)) return EBADF;
    const proc = sched.currentProcess() orelse return EIO;
    const cloexec = flags & FD_CLOEXEC != 0;
    const result = if (new == std.math.maxInt(u64))
        fd_mod.dup(&proc.files, @intCast(old), fd_mod.FD_BASE, cloexec)
    else if (new > std.math.maxInt(i32))
        return EBADF
    else
        fd_mod.dupTo(&proc.files, @intCast(old), @intCast(new), cloexec);
    return result catch |e| vfsErrno(e);
}

/// fcntl's descriptor commands: 0 DUPFD (lowest at or above `arg`),
/// 1 DUPFD_CLOEXEC, 2 GETFD, 3 SETFD, 4 GETFL, 5 SETFL.
fn sysFdControl(fd: u64, command: u64, arg: u64) i64 {
    if (fd > std.math.maxInt(i32)) return EBADF;
    const proc = sched.currentProcess() orelse return EIO;
    const n: i32 = @intCast(fd);
    const installed = fd_mod.lookup(&proc.files, n) orelse return EBADF;
    defer installed.release();
    return switch (command) {
        0, 1 => blk: {
            if (arg >= fd_mod.MAX_OPEN) break :blk EINVAL;
            break :blk fd_mod.dup(&proc.files, n, @intCast(arg), command == 1) catch |e| vfsErrno(e);
        },
        2 => if (fd_mod.cloexecOf(&proc.files, n)) |c| @intFromBool(c) else |e| vfsErrno(e),
        3 => if (fd_mod.setCloexec(&proc.files, n, arg & 1 != 0)) |_| 0 else |e| vfsErrno(e),
        4 => installed.statusFlags(),
        5 => if (fd_mod.setStatus(&proc.files, n, @truncate(arg))) |_| 0 else |e| vfsErrno(e),
        // Seals, for tmpfs files and memfds.
        6, 7 => switch (installed.object) {
            .node => |f| switch (f.node) {
                .tmp => |inode| if (command == 7)
                    @as(i64, tmpfs.seals(inode))
                else if (tmpfs.addSeals(inode, @truncate(arg))) |_| 0 else |e| switch (e) {
                    error.Sealed => EPERM,
                    error.Busy => EBUSY,
                    else => EINVAL,
                },
                else => EINVAL,
            },
            else => EINVAL,
        },
        // Record locks: 8-10 POSIX GETLK/SETLK/SETLKW, 11-13 the same for
        // open-file-description locks.
        8...13 => recordLockControl(proc, installed, command, arg),
        else => EINVAL,
    };
}

/// The record fcntl commands take (the same layout as Linux's struct
/// flock). kind: 0 shared, 1 exclusive, 2 unlock; whence: 0 start of file,
/// 1 current offset, 2 end; length 0 runs to the end of the file, however
/// it grows, and a negative length covers the bytes before `start`.
const RecordLock = extern struct {
    kind: u16,
    whence: u16,
    reserved: u32 = 0,
    start: i64,
    length: i64,
    pid: i32,
    reserved2: u32 = 0,
};
const EDEADLK: i64 = -35;
const ENOLCK: i64 = -37;
const EOVERFLOW: i64 = -75;

fn recordLockControl(proc: *task_mod.Process, desc: *fd_mod.Description, command: u64, address: u64) i64 {
    const file = switch (desc.object) {
        .node => |*file| file,
        else => return EINVAL,
    };
    const pml4 = vmm.currentCr3();
    var request: RecordLock = undefined;
    validate.copyFromUser(pml4, std.mem.asBytes(&request), address, @sizeOf(RecordLock)) catch return EFAULT;
    const description_owned = command >= 11;
    if (description_owned and request.pid != 0) return EINVAL;
    const kind: ?record_lock.Kind = switch (request.kind) {
        0 => .read,
        1 => .write,
        2 => null,
        else => return EINVAL,
    };
    const base: i128 = switch (request.whence) {
        0 => 0,
        1 => fd_mod.position(desc),
        2 => file.node.size(),
        else => return EINVAL,
    };
    const start = base + request.start;
    var first: i128 = start;
    var last: i128 = undefined;
    if (request.length > 0) {
        last = start + request.length - 1;
    } else if (request.length == 0) {
        last = record_lock.TO_END;
    } else {
        first = start + request.length;
        last = start - 1;
    }
    if (first < 0) return EINVAL;
    if (last > std.math.maxInt(i64) and request.length != 0) return EOVERFLOW;
    const key = record_lock.keyOf(&file.node);
    const owner = if (description_owned) record_lock.Owner.description(@intFromPtr(desc)) else record_lock.Owner.process(proc.pid);

    if (command == 8 or command == 11) {
        // F_GETLK: describe a lock that would block this one, or report
        // that none would by setting kind to unlock.
        const wanted = kind orelse return EINVAL;
        if (record_lock.find(key, owner, @intCast(first), @intCast(last), wanted)) |found| {
            request = .{
                .kind = @intFromEnum(found.kind),
                .whence = 0,
                .start = @intCast(found.first),
                .length = if (found.last == record_lock.TO_END) 0 else @intCast(found.last - found.first + 1),
                .pid = found.pid,
            };
        } else request.kind = 2;
        validate.copyToUser(pml4, address, std.mem.asBytes(&request), @sizeOf(RecordLock)) catch return EFAULT;
        return 0;
    }

    // A shared lock needs a readable descriptor, an exclusive one a writable.
    const status = desc.statusFlags();
    if (kind) |k| switch (k) {
        .read => if (status & vfs.OPEN_READ == 0) return EBADF,
        .write => if (status & vfs.OPEN_WRITE == 0) return EBADF,
    };
    const wait = command == 10 or command == 13;
    const pid: i32 = if (description_owned) -1 else @intCast(proc.pid);
    io.sti();
    defer io.cli();
    record_lock.set(key, owner, pid, @intCast(first), @intCast(last), kind, wait) catch |e| return switch (e) {
        error.WouldBlock => EAGAIN,
        error.Deadlock => EDEADLK,
        error.Interrupted => EINTR,
        error.OutOfMemory => ENOLCK,
        error.InvalidArgument => EINVAL,
    };
    return 0;
}

// ── Readiness: epoll and poll ───────────────────────────────────────────────

fn epollErrno(e: epoll.Error) i64 {
    return switch (e) {
        epoll.Error.BadFd => EBADF,
        epoll.Error.Exists => EEXIST,
        epoll.Error.NotFound => ENOENT,
        epoll.Error.NotPermitted => EPERM,
        epoll.Error.InvalidArgument => EINVAL,
        epoll.Error.OutOfMemory => ENOMEM,
        epoll.Error.Interrupted => EINTR,
    };
}

fn sysEpollCreate(flags: u64) i64 {
    if (flags & ~FD_CLOEXEC != 0) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    return fd_mod.createEpoll(&proc.files, flags & FD_CLOEXEC != 0) catch |e| vfsErrno(e);
}

/// The epoll instance behind `epfd`, referenced through its description.
fn epollOf(epfd: u64) error{ BadFd, NotEpoll }!struct { desc: *fd_mod.Description, ep: *epoll.Epoll } {
    const desc = descriptionOf(epfd) orelse return error.BadFd;
    switch (desc.object) {
        .epoll => |ep| return .{ .desc = desc, .ep = ep },
        else => {
            desc.release();
            return error.NotEpoll;
        },
    }
}

/// epoll_event is packed on x86-64: u32 events, then u64 data (12 bytes).
const EPOLL_EVENT_SIZE = 12;

fn sysEpollCtl(epfd: u64, op: u64, target: u64, event_ptr: u64) i64 {
    const instance = epollOf(epfd) catch |e| return if (e == error.BadFd) EBADF else EINVAL;
    defer instance.desc.release();
    if (op < 1 or op > 3) return EINVAL;
    if (target == epfd) return EINVAL;
    const desc = descriptionOf(target) orelse return EBADF;
    defer desc.release();
    var interest: epoll.Event = .{ .events = 0, .data = 0 };
    if (op != 2) {
        var raw: [EPOLL_EVENT_SIZE]u8 = undefined;
        validate.copyFromUser(vmm.currentCr3(), &raw, event_ptr, EPOLL_EVENT_SIZE) catch return EFAULT;
        interest = .{ .events = std.mem.readInt(u32, raw[0..4], .little), .data = std.mem.readInt(u64, raw[4..12], .little) };
    }
    epoll.control(instance.ep, @enumFromInt(op), @intCast(target), desc, interest) catch |e| return epollErrno(e);
    return 0;
}

/// At most this many events per call; a caller asking for more gets fewer.
const EPOLL_BATCH = 128;

fn sysEpollWait(epfd: u64, out: u64, max: u64, timeout: u64) i64 {
    if (max == 0 or max > std.math.maxInt(i32)) return EINVAL;
    const instance = epollOf(epfd) catch |e| return if (e == error.BadFd) EBADF else EINVAL;
    defer instance.desc.release();
    var events: [EPOLL_BATCH]epoll.Event = undefined;
    const want: usize = @intCast(@min(max, EPOLL_BATCH));
    io.sti();
    defer io.cli();
    const ready = epoll.wait(instance.ep, events[0..want], @bitCast(timeout)) catch |e| return epollErrno(e);
    var raw: [EPOLL_BATCH * EPOLL_EVENT_SIZE]u8 = undefined;
    for (events[0..ready], 0..) |item, i| {
        const at = raw[i * EPOLL_EVENT_SIZE ..][0..EPOLL_EVENT_SIZE];
        std.mem.writeInt(u32, at[0..4], item.events, .little);
        std.mem.writeInt(u64, at[4..12], item.data, .little);
    }
    const bytes = ready * EPOLL_EVENT_SIZE;
    validate.copyToUser(vmm.currentCr3(), out, raw[0..bytes], bytes) catch return EFAULT;
    return @intCast(ready);
}

/// struct pollfd: i32 fd, i16 events, i16 revents.
const POLLFD_SIZE = 8;
const MAX_POLL = 1024;

fn sysPoll(fds_ptr: u64, nfds: u64, timeout: u64) i64 {
    if (nfds > MAX_POLL) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    const n: usize = @intCast(nfds);
    if (n == 0) {
        // A plain sleep.
        const ms: i64 = @bitCast(timeout);
        if (ms > 0) {
            io.sti();
            defer io.cli();
            sched.sleepMs(@intCast(ms));
        }
        return 0;
    }
    const raw = heap.alloc(n * POLLFD_SIZE) catch return ENOMEM;
    defer heap.free(raw);
    validate.copyFromUser(vmm.currentCr3(), raw[0 .. n * POLLFD_SIZE], fds_ptr, n * POLLFD_SIZE) catch return EFAULT;
    const entries_raw = heap.alloc(n * @sizeOf(epoll.PollEntry)) catch return ENOMEM;
    defer heap.free(entries_raw);
    const entries: [*]epoll.PollEntry = @ptrCast(@alignCast(entries_raw));
    for (0..n) |i| {
        const at = raw[i * POLLFD_SIZE ..][0..POLLFD_SIZE];
        entries[i] = .{
            .number = std.mem.readInt(i32, at[0..4], .little),
            .requested = std.mem.readInt(u16, at[4..6], .little),
        };
    }
    io.sti();
    const ready = epoll.poll(&proc.files, entries[0..n], @bitCast(timeout));
    io.cli();
    const result = ready catch |e| return epollErrno(e);
    for (0..n) |i| {
        const at = raw[i * POLLFD_SIZE ..][0..POLLFD_SIZE];
        std.mem.writeInt(u16, at[6..8], @truncate(entries[i].returned), .little);
    }
    validate.copyToUser(vmm.currentCr3(), fds_ptr, raw[0 .. n * POLLFD_SIZE], n * POLLFD_SIZE) catch return EFAULT;
    return @intCast(result);
}

// ── Local socket pairs ──────────────────────────────────────────────────────

/// socketpair: 1 stream, 2 datagram, 5 seqpacket; flags as for pipe.
fn sysSocketPair(kind: u64, flags: u64, out: u64) i64 {
    if (flags & ~(FD_NONBLOCK | FD_CLOEXEC) != 0) return EINVAL;
    const socket_kind: unix_socket.Kind = switch (kind) {
        1 => .stream,
        2 => .datagram,
        5 => .seqpacket,
        else => return EINVAL,
    };
    const proc = sched.currentProcess() orelse return EIO;
    const fds = fd_mod.createSocketPair(&proc.files, socket_kind, flags & FD_NONBLOCK != 0, flags & FD_CLOEXEC != 0) catch |e| return vfsErrno(e);
    validate.copyToUser(vmm.currentCr3(), out, std.mem.asBytes(&fds), @sizeOf([2]i32)) catch {
        fd_mod.close(&proc.files, fds[0]) catch {};
        fd_mod.close(&proc.files, fds[1]) catch {};
        return EFAULT;
    };
    return 0;
}

/// The message sendmsg and recvmsg take: data as an iovec array, and
/// descriptors as an i32 array. recvmsg writes back how many descriptors it
/// installed and `flags` (1 data truncated, 2 descriptors dropped).
const NativeMessage = extern struct {
    iov: u64,
    iov_count: u64,
    fds: u64,
    fd_count: u32,
    flags: u32,
};
const Iovec = extern struct { base: u64, len: u64 };
/// sendmsg/recvmsg flags.
const MSG_DONTWAIT: u64 = 1;
const MSG_CLOEXEC: u64 = 2;
const MAX_IOV = 1024;

fn socketOf(number: u64) error{ BadFd, NotSocket }!struct { desc: *fd_mod.Description, sock: fd_mod.SocketEnd } {
    const desc = descriptionOf(number) orelse return error.BadFd;
    switch (desc.object) {
        .socket => |sock| return .{ .desc = desc, .sock = sock },
        else => {
            desc.release();
            return error.NotSocket;
        },
    }
}

/// Copy the message header and its iovec array in; returns the vectors in a
/// heap buffer the caller frees, and their total length (capped).
fn readMessage(address: u64, message: *NativeMessage) error{ Fault, Invalid, NoMemory }![]Iovec {
    const pml4 = vmm.currentCr3();
    validate.copyFromUser(pml4, std.mem.asBytes(message), address, @sizeOf(NativeMessage)) catch return error.Fault;
    if (message.iov_count > MAX_IOV) return error.Invalid;
    const vector_count: usize = @intCast(message.iov_count);
    if (vector_count == 0) return &.{};
    const raw = heap.alloc(vector_count * @sizeOf(Iovec)) catch return error.NoMemory;
    const vectors: [*]Iovec = @ptrCast(@alignCast(raw));
    validate.copyFromUser(pml4, raw[0 .. vector_count * @sizeOf(Iovec)], message.iov, vector_count * @sizeOf(Iovec)) catch {
        heap.free(raw);
        return error.Fault;
    };
    return vectors[0..vector_count];
}

fn messageErrno(e: error{ Fault, Invalid, NoMemory }) i64 {
    return switch (e) {
        error.Fault => EFAULT,
        error.Invalid => EINVAL,
        error.NoMemory => ENOMEM,
    };
}

fn totalLength(vectors: []const Iovec) ?usize {
    var total: usize = 0;
    for (vectors) |v| total = std.math.add(usize, total, @intCast(v.len)) catch return null;
    return total;
}

fn sysSendMsg(number: u64, address: u64, flags: u64) i64 {
    if (flags & ~MSG_DONTWAIT != 0) return EINVAL;
    const target = socketOf(number) catch |e| return if (e == error.BadFd) EBADF else ENOTSOCK;
    defer target.desc.release();
    var message: NativeMessage = undefined;
    const vectors = readMessage(address, &message) catch |e| return messageErrno(e);
    defer if (vectors.len > 0) heap.free(@ptrCast(vectors.ptr));
    const requested = totalLength(vectors) orelse return EINVAL;
    const length = @min(requested, unix_socket.CAPACITY);
    if (target.sock.pair.kind != .stream and requested > unix_socket.CAPACITY) return EMSGSIZE;
    if (message.fd_count > unix_socket.MAX_RIGHTS) return EINVAL;

    const pml4 = vmm.currentCr3();
    const data = heap.alloc(@max(length, 1)) catch return ENOMEM;
    defer heap.free(data);
    var gathered: usize = 0;
    for (vectors) |v| {
        const take = @min(@as(usize, @intCast(v.len)), length - gathered);
        if (take == 0) break;
        validate.copyFromUser(pml4, data[gathered .. gathered + take], v.base, take) catch return EFAULT;
        gathered += take;
    }

    // Take a reference on every description being passed.
    var numbers: [unix_socket.MAX_RIGHTS]i32 = undefined;
    const rights_count: usize = message.fd_count;
    if (rights_count > 0) {
        validate.copyFromUser(pml4, std.mem.sliceAsBytes(numbers[0..rights_count]), message.fds, rights_count * 4) catch return EFAULT;
    }
    var rights: [unix_socket.MAX_RIGHTS]*fd_mod.Description = undefined;
    var taken: usize = 0;
    defer for (rights[0..taken]) |d| d.release();
    for (numbers[0..rights_count]) |n| {
        rights[taken] = descriptionOf(@bitCast(@as(i64, n))) orelse return EBADF;
        taken += 1;
    }

    io.sti();
    defer io.cli();
    const nonblock = flags & MSG_DONTWAIT != 0 or target.desc.statusFlags() & vfs.OPEN_NONBLOCK != 0;
    const sent = unix_socket.send(target.sock.pair, target.sock.end, data[0..length], rights[0..taken], nonblock) catch |e| return vfsErrno(fd_mod.socketError(e));
    // The message now owns those references.
    taken = 0;
    return @intCast(sent);
}

fn sysRecvMsg(number: u64, address: u64, flags: u64) i64 {
    if (flags & ~(MSG_DONTWAIT | MSG_CLOEXEC) != 0) return EINVAL;
    const target = socketOf(number) catch |e| return if (e == error.BadFd) EBADF else ENOTSOCK;
    defer target.desc.release();
    const proc = sched.currentProcess() orelse return EIO;
    var message: NativeMessage = undefined;
    const vectors = readMessage(address, &message) catch |e| return messageErrno(e);
    defer if (vectors.len > 0) heap.free(@ptrCast(vectors.ptr));
    const capacity = @min(totalLength(vectors) orelse return EINVAL, unix_socket.CAPACITY);
    const data = heap.alloc(@max(capacity, 1)) catch return ENOMEM;
    defer heap.free(data);

    const got = blk: {
        io.sti();
        defer io.cli();
        const nonblock = flags & MSG_DONTWAIT != 0 or target.desc.statusFlags() & vfs.OPEN_NONBLOCK != 0;
        break :blk unix_socket.receive(target.sock.pair, target.sock.end, data[0..capacity], nonblock) catch |e| return vfsErrno(fd_mod.socketError(e));
    };

    // Install what arrived; what does not fit is closed, as on Linux.
    var installed: [unix_socket.MAX_RIGHTS]i32 = undefined;
    var installed_count: usize = 0;
    var dropped = false;
    for (got.rights[0..got.right_count]) |carried| {
        if (installed_count < message.fd_count) {
            if (fd_mod.install(&proc.files, carried, fd_mod.FD_BASE, flags & MSG_CLOEXEC != 0)) |n| {
                installed[installed_count] = n;
                installed_count += 1;
                continue;
            } else |_| {}
        }
        carried.release();
        dropped = true;
    }

    const pml4 = vmm.currentCr3();
    var scattered: usize = 0;
    for (vectors) |v| {
        const put = @min(@as(usize, @intCast(v.len)), got.bytes - scattered);
        if (put == 0) break;
        validate.copyToUser(pml4, v.base, data[scattered .. scattered + put], put) catch return EFAULT;
        scattered += put;
    }
    if (installed_count > 0) {
        validate.copyToUser(pml4, message.fds, std.mem.sliceAsBytes(installed[0..installed_count]), installed_count * 4) catch return EFAULT;
    }
    message.fd_count = @intCast(installed_count);
    message.flags = (if (got.truncated) @as(u32, 1) else 0) | (if (dropped) @as(u32, 2) else 0);
    validate.copyToUser(pml4, address, std.mem.asBytes(&message), @sizeOf(NativeMessage)) catch return EFAULT;
    return @intCast(got.bytes);
}

fn sysShutdown(number: u64, how: u64) i64 {
    if (how > 2) return EINVAL;
    const target = socketOf(number) catch |e| return if (e == error.BadFd) EBADF else ENOTSOCK;
    defer target.desc.release();
    unix_socket.shutdown(target.sock.pair, target.sock.end, @intCast(how));
    return 0;
}

fn sysEventFd(initial: u64, flags: u64) i64 {
    if (flags & ~(FD_NONBLOCK | FD_CLOEXEC | EFD_SEMAPHORE) != 0) return EINVAL;
    if (initial > std.math.maxInt(u32)) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;
    return fd_mod.createEventFd(&proc.files, @intCast(initial), flags & EFD_SEMAPHORE != 0, flags & FD_NONBLOCK != 0, flags & FD_CLOEXEC != 0) catch |e| vfsErrno(e);
}

/// What `statfs` reports for the filesystem holding a path.
const FsStatus = extern struct {
    total_bytes: u64,
    free_bytes: u64,
    /// 1 when nothing on it can be changed.
    read_only: u32,
    reserved: u32 = 0,
};

fn sysStatfs(path_ptr: u64, path_len: u64, out: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    const usage = vfs.usage(name) catch |e| return vfsErrno(e);
    const status = FsStatus{ .total_bytes = usage.total_bytes, .free_bytes = usage.free_bytes, .read_only = @intFromBool(usage.read_only) };
    validate.copyToUser(vmm.currentCr3(), out, std.mem.asBytes(&status), @sizeOf(FsStatus)) catch return EFAULT;
    return 0;
}

fn sysClose(fd: u64) i64 {
    if (fd > std.math.maxInt(i32)) return EBADF;
    const proc = sched.currentProcess() orelse return EIO;
    fd_mod.close(&proc.files, @intCast(fd)) catch |e| return vfsErrno(e);
    return 0;
}

fn sysRead(fd: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;
    const desc = descriptionOf(fd) orelse return EBADF;
    defer desc.release();
    // Read into kernel memory first, then copy out: the object never writes
    // through an unvalidated user pointer. Pipe, socket, eventfd and console
    // reads may block, which needs interrupts on.
    io.sti();
    defer io.cli();
    var kbuf: [4096]u8 = undefined;
    const n = fd_mod.read(desc, kbuf[0..@intCast(len)]) catch |e| return vfsErrno(e);
    validate.copyToUser(vmm.currentCr3(), buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

// ── Working directory, paths and program launch ─────────────────────────────

const ERANGE: i64 = -34;
const E2BIG: i64 = -7;

fn sysChdir(path_ptr: u64, path_len: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    const node = vfs.resolve(name) catch |e| return vfsErrno(e);
    defer vfs.release(node);
    if (!node.isDir()) return ENOTDIR;
    process.setCurrentDirectory(name);
    return 0;
}

/// Writes the working directory and a NUL; returns the length with the NUL.
fn sysGetcwd(out: u64, size: u64) i64 {
    var cwd: [vfs.MAX_PATH + 1]u8 = undefined;
    const path = process.currentDirectory(cwd[0..vfs.MAX_PATH]);
    if (size < path.len + 1) return ERANGE;
    cwd[path.len] = 0;
    validate.copyToUser(vmm.currentCr3(), out, cwd[0 .. path.len + 1], path.len + 1) catch return EFAULT;
    return @intCast(path.len + 1);
}

/// The canonical absolute form of `path`, taken relative to the directory
/// behind `dirfd` (or, for -1, the working directory). For the *at() calls.
fn sysResolvePath(dirfd: u64, path_ptr: u64, path_len: u64, out: u64, capacity: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;
    var raw: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(vmm.currentCr3(), &raw, path_ptr, @intCast(path_len)) catch return EFAULT;
    const path = raw[0..@intCast(path_len)];
    var base_buffer: [vfs.MAX_PATH]u8 = undefined;
    const base: ?[]const u8 = if (dirfd == std.math.maxInt(u64) or path[0] == '/') null else blk: {
        if (dirfd > std.math.maxInt(i32)) return EBADF;
        const proc = sched.currentProcess() orelse return EIO;
        break :blk fd_mod.directoryPath(&proc.files, @intCast(dirfd), &base_buffer) catch |e| return vfsErrno(e);
    };
    var result: [vfs.MAX_PATH]u8 = undefined;
    const canonical = absolutePath(base, path, &result) catch |e| return vfsErrno(e);
    if (capacity < canonical.len) return ERANGE;
    validate.copyToUser(vmm.currentCr3(), out, canonical, canonical.len) catch return EFAULT;
    return @intCast(canonical.len);
}

/// What spawn_process takes. `args` and `env` are NUL-terminated strings
/// back to back; `fds` pairs {child: i32, parent: i32}, and the program
/// starts with exactly those descriptors; `cwd` (length 0: the caller's).
const SpawnRequest = extern struct {
    path: u64,
    path_len: u64,
    args: u64,
    args_len: u64,
    env: u64,
    env_len: u64,
    fds: u64,
    fd_count: u64,
    cwd: u64,
    cwd_len: u64,
};

fn countStrings(block: []const u8) ?usize {
    if (block.len == 0) return 0;
    if (block[block.len - 1] != 0) return null;
    return std.mem.count(u8, block, &[_]u8{0});
}

fn sysSpawnProcess(request_ptr: u64) i64 {
    const pml4 = vmm.currentCr3();
    var request: SpawnRequest = undefined;
    validate.copyFromUser(pml4, std.mem.asBytes(&request), request_ptr, @sizeOf(SpawnRequest)) catch return EFAULT;
    var path_buffer: [vfs.MAX_PATH]u8 = undefined;
    const path = copyPath(&path_buffer, request.path, request.path_len) catch |e| return pathErrno(e);
    if (request.args_len + request.env_len > process.ARG_MAX) return E2BIG;
    if (request.fd_count > fd_mod.MAX_OPEN) return EINVAL;
    const proc = sched.currentProcess() orelse return EIO;

    var cwd_buffer: [vfs.MAX_PATH]u8 = undefined;
    const cwd: ?[]const u8 = if (request.cwd_len == 0) null else blk: {
        const dir = copyPath(&cwd_buffer, request.cwd, request.cwd_len) catch |e| return pathErrno(e);
        const node = vfs.resolve(dir) catch |e| return vfsErrno(e);
        defer vfs.release(node);
        if (!node.isDir()) return ENOTDIR;
        break :blk dir;
    };

    // Arguments and environment, copied into one block the spawn will own.
    const block_len: usize = @intCast(request.args_len + request.env_len);
    var arguments: process.Arguments = .{};
    if (block_len > 0) {
        const block = heap.alloc(block_len) catch return ENOMEM;
        const args = block[0..@intCast(request.args_len)];
        const env = block[@intCast(request.args_len)..block_len];
        validate.copyFromUser(pml4, args, request.args, args.len) catch {
            heap.free(block);
            return EFAULT;
        };
        validate.copyFromUser(pml4, env, request.env, env.len) catch {
            heap.free(block);
            return EFAULT;
        };
        const argc = countStrings(args);
        const envc = countStrings(env);
        if (argc == null or envc == null or argc.? + envc.? > process.MAX_STRINGS) {
            heap.free(block);
            return EINVAL;
        }
        arguments = .{ .block = block[0..block_len], .argc = argc.?, .envc = envc.?, .owned = true };
    }

    // Descriptors: a reference on each granted description.
    const grant_count: usize = @intCast(request.fd_count);
    var grants: []process.Grant = &.{};
    if (grant_count > 0) {
        const pairs_raw = heap.alloc(grant_count * 8) catch {
            arguments.free();
            return ENOMEM;
        };
        defer heap.free(pairs_raw);
        validate.copyFromUser(pml4, pairs_raw[0 .. grant_count * 8], request.fds, grant_count * 8) catch {
            arguments.free();
            return EFAULT;
        };
        const pairs: [*]const [2]i32 = @ptrCast(@alignCast(pairs_raw));
        const grants_raw = heap.alloc(grant_count * @sizeOf(process.Grant)) catch {
            arguments.free();
            return ENOMEM;
        };
        const list: [*]process.Grant = @ptrCast(@alignCast(grants_raw));
        var taken: usize = 0;
        var seen = std.StaticBitSet(fd_mod.MAX_OPEN).initEmpty();
        const failure: ?i64 = for (pairs[0..grant_count]) |pair| {
            if (pair[0] < 0 or pair[0] >= fd_mod.MAX_OPEN or seen.isSet(@intCast(pair[0]))) break EINVAL;
            seen.set(@intCast(pair[0]));
            const desc = fd_mod.lookup(&proc.files, pair[1]) orelse break EBADF;
            list[taken] = .{ .number = pair[0], .desc = desc };
            taken += 1;
        } else null;
        if (failure) |code| {
            for (list[0..taken]) |grant| grant.desc.release();
            heap.free(grants_raw);
            arguments.free();
            return code;
        }
        grants = list[0..grant_count];
    }

    const tid = process.spawnWith(path, .{
        .arguments = arguments,
        .grants = grants,
        .exact_descriptors = true,
        .cwd = cwd,
    }) catch |e| return switch (e) {
        error.NotFound, error.NotMounted => ENOENT,
        error.OutOfMemory => ENOMEM,
        error.BadImage => ENOEXEC,
    };
    return @intCast(tid);
}

const ECHILD: i64 = -10;
const ENOEXEC: i64 = -8;

fn sysSpawn(path_ptr: u64, path_len: u64) i64 {
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);
    const tid = process.spawnPath(name) catch |e| {
        return switch (e) {
            error.NotFound, error.NotMounted => ENOENT,
            error.OutOfMemory => -12,
            error.BadImage => ENOEXEC,
        };
    };
    return @intCast(tid);
}

/// Wait for a task to become a zombie and return its exit code.
///
/// `flags` bit 0 is WNOHANG: return -EAGAIN immediately if the task is still
/// running. A supervisor with more than one service needs this — blocking on
/// each in turn means a long-running service prevents noticing that any other
/// one died.
pub const WNOHANG: u64 = 1;

fn sysWait(pid: u64, flags: u64) i64 {
    if (pid == 0 or pid > std.math.maxInt(u32)) return ECHILD;
    const tid: u32 = @intCast(pid);
    const parent = sched.currentTask() orelse return ECHILD;
    const owner = parent.ownerId();

    if (flags & WNOHANG != 0) {
        return switch (sched.collectChild(tid, owner)) {
            .exited => |code| code,
            .running => EAGAIN,
            .missing => ECHILD,
        };
    }

    // We arrive with IF clear, and the child needs timer interrupts to be
    // scheduled at all.
    io.sti();
    defer io.cli();

    while (true) {
        if (sched.interruptPending()) return EINTR;
        // Join the child's exit channel before checking its state. If the
        // exit lands between the check and commitWait, its wake removes us
        // from the queue and commitWait returns without sleeping.
        const channel = switch (sched.collectChild(tid, owner)) {
            .exited => |code| return code,
            .missing => return ECHILD,
            .running => |channel| channel,
        };
        sched.prepareWait(channel);
        switch (sched.collectChild(tid, owner)) {
            .exited => |code| {
                sched.cancelWait();
                return code;
            },
            .missing => {
                sched.cancelWait();
                return ECHILD;
            },
            .running => sched.commitWait(),
        }
    }
}

/// Sleep for `ms` milliseconds. Yields rather than spinning, so other work
/// runs while a supervisor is idle between polls.
fn sysSleepMs(ms: u64) i64 {
    if (ms == 0) {
        sched.yield();
        return 0;
    }
    // Interrupts on for the duration: MSR_FMASK clears IF on syscall entry,
    // and a thread that sleeps with interrupts off never sees the timer that
    // is supposed to wake it.
    io.sti();
    defer io.cli();

    sched.sleepMs(ms);
    // Cut short by a caught signal (or the program exiting).
    if (sched.interruptPending()) return EINTR;
    return 0;
}

/// One entry as handed to userspace. Must match pulp.DirEntry.
const UserDirEntry = extern struct {
    inode: u32,
    type: u8,
    name_len: u8,
    name: [128]u8,
};

const ReaddirCtx = struct {
    // All bytes cross the privilege boundary, including unused name tails.
    entries: [32]UserDirEntry = std.mem.zeroes([32]UserDirEntry),
    count: usize = 0,
    max: usize = 0,
    skip: u64 = 0,
};

fn collectEntry(ctx_ptr: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool {
    const ctx: *ReaddirCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.count >= ctx.max or ctx.count >= ctx.entries.len) return false;
    if (name.len > 128) return true;
    if (ctx.skip > 0) {
        ctx.skip -= 1;
        return true;
    }

    var e = &ctx.entries[ctx.count];
    e.inode = ino;
    e.type = dtype;
    e.name_len = @intCast(name.len);
    @memcpy(e.name[0..name.len], name);
    ctx.count += 1;
    return true;
}

fn sysReaddir(path_ptr: u64, path_len: u64, out: u64, max: u64, skip: u64) i64 {
    if (max == 0) return 0;
    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    const name = copyPath(&path, path_ptr, path_len) catch |e| return pathErrno(e);

    var ctx = ReaddirCtx{ .max = @min(max, 32), .skip = skip };
    vfs.iterateDir(name, &ctx, collectEntry) catch |e| {
        return vfsErrno(e);
    };

    const bytes = ctx.count * @sizeOf(UserDirEntry);
    const src: [*]const u8 = @ptrCast(&ctx.entries);
    validate.copyToUser(pml4, out, src[0..bytes], bytes) catch return EFAULT;

    return @intCast(ctx.count);
}

/// Entries of an open directory from its current position, which advances
/// past them; seeking to 0 starts over.
fn sysReaddirFd(fd: u64, out: u64, max: u64) i64 {
    if (fd > std.math.maxInt(i32)) return EBADF;
    if (max == 0) return 0;
    const proc = sched.currentProcess() orelse return EIO;
    const cursor = fd_mod.DirRead.begin(&proc.files, @intCast(fd)) catch |e| return vfsErrno(e);
    var ctx = ReaddirCtx{ .max = @min(max, 32), .skip = cursor.start() };
    const listed = cursor.entries(&ctx, collectEntry);
    cursor.end(if (listed) |_| ctx.count else |_| 0);
    listed catch |e| return vfsErrno(e);

    const bytes = ctx.count * @sizeOf(UserDirEntry);
    const src: [*]const u8 = @ptrCast(&ctx.entries);
    validate.copyToUser(vmm.currentCr3(), out, src[0..bytes], bytes) catch return EFAULT;
    return @intCast(ctx.count);
}

// ── IPC ─────────────────────────────────────────────────────────────────────

const EEXIST: i64 = -17;
const EAGAIN: i64 = -11;
const EINVAL: i64 = -22;
const EMSGSIZE: i64 = -90;

fn ipcErrno(e: ipc.Error) i64 {
    return switch (e) {
        ipc.Error.NoSuchPort => ENOENT,
        ipc.Error.NameTaken => EEXIST,
        ipc.Error.NameTooLong => ENAMETOOLONG,
        ipc.Error.BadHandle, ipc.Error.WrongType => EBADF,
        ipc.Error.QueueFull, ipc.Error.QueueEmpty => EAGAIN,
        ipc.Error.MessageTooLarge => EMSGSIZE,
        ipc.Error.TooManyHandles => EMFILE,
        ipc.Error.OutOfMemory => -12,
        ipc.Error.Interrupted => EINTR,
    };
}

fn copyName(ptr: u64, len: u64, out: []u8) ?[]const u8 {
    if (len == 0 or len > out.len) return null;
    const pml4 = vmm.currentCr3();
    validate.copyFromUser(pml4, out, ptr, @intCast(len)) catch return null;
    return out[0..@intCast(len)];
}

fn sysPortCreate(name_ptr: u64, name_len: u64) i64 {
    var buf: [32]u8 = undefined;
    const name = copyName(name_ptr, name_len, &buf) orelse return EFAULT;
    return ipc.portCreate(name) catch |e| ipcErrno(e);
}

fn sysPortConnect(name_ptr: u64, name_len: u64) i64 {
    var buf: [32]u8 = undefined;
    const name = copyName(name_ptr, name_len, &buf) orelse return EFAULT;
    return ipc.portConnect(name) catch |e| ipcErrno(e);
}

fn sysPortSend(h: u64, opcode: u64, payload_ptr: u64, payload_len: u64) i64 {
    if (payload_len > ipc.MAX_PAYLOAD) return EMSGSIZE;

    const pml4 = vmm.currentCr3();
    var buf: [ipc.MAX_PAYLOAD]u8 = undefined;
    if (payload_len > 0) {
        validate.copyFromUser(pml4, &buf, payload_ptr, @intCast(payload_len)) catch return EFAULT;
    }

    const seq = ipc.portSend(
        @bitCast(h),
        @truncate(opcode),
        buf[0..@intCast(payload_len)],
    ) catch |e| return ipcErrno(e);

    return @intCast(seq);
}

/// Returns `(opcode << 32) | length`. Packing them into one value avoids a
/// second out-parameter; payloads are capped at 4096 so the length always fits
/// in the low half.
fn sysPortRecv(h: u64, buf_ptr: u64, buf_len: u64, blocking: u64) i64 {
    if (buf_len > ipc.MAX_PAYLOAD) return EMSGSIZE;

    var kbuf: [ipc.MAX_PAYLOAD]u8 = undefined;
    const r = ipc.portRecv(
        @bitCast(h),
        kbuf[0..@intCast(buf_len)],
        blocking != 0,
    ) catch |e| return ipcErrno(e);

    const pml4 = vmm.currentCr3();
    validate.copyToUser(pml4, buf_ptr, kbuf[0..r.len], r.len) catch return EFAULT;

    const packed_result: u64 = (@as(u64, r.header.opcode) << 32) | @as(u64, r.len);
    return @bitCast(packed_result);
}

fn sysShmCreate(name_ptr: u64, name_len: u64, size: u64) i64 {
    var buf: [32]u8 = undefined;
    var name: []const u8 = buf[0..0];
    if (name_len > 0) {
        name = copyName(name_ptr, name_len, &buf) orelse return EFAULT;
    }
    return ipc.shmCreate(name, @intCast(size)) catch |e| ipcErrno(e);
}

fn sysShmOpen(name_ptr: u64, name_len: u64) i64 {
    var buf: [32]u8 = undefined;
    const name = copyName(name_ptr, name_len, &buf) orelse return EFAULT;
    return ipc.shmOpen(name) catch |e| ipcErrno(e);
}

fn sysShmMap(h: u64, writable: u64) i64 {
    // A failed mapping rolls back with a shootdown, which needs interrupts.
    io.sti();
    defer io.cli();
    const addr = ipc.shmMap(@bitCast(h), writable != 0) catch |e| return ipcErrno(e);
    return @bitCast(addr);
}

fn sysHandleClose(h: u64) i64 {
    ipc.handleClose(@bitCast(h)) catch |e| return ipcErrno(e);
    return 0;
}

// ── Display and input ───────────────────────────────────────────────────────

/// Framebuffer geometry, as handed to userspace.
const FbInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
    reserved: u8,
};

var fb_owner: u32 = 0;

/// Claim the framebuffer. Only one process may hold it: the compositor owns
/// the screen, and the kernel console steps aside so the two do not fight over
/// the same pixels.
fn sysFbAcquire(info_ptr: u64) i64 {
    const f = framebuffer.get() orelse return -19; // ENODEV

    const t = sched.currentTask() orelse return EIO;
    if (fb_owner != 0 and fb_owner != t.ownerId()) return -16; // EBUSY
    fb_owner = t.ownerId();

    // Stop the kernel console drawing once a compositor is live. Panics still
    // reach the serial line, which is the console that matters when things
    // have gone wrong anyway.
    fbcon.suspendOutput();

    const info = FbInfo{
        .width = @intCast(f.width),
        .height = @intCast(f.height),
        .pitch = @intCast(f.pitch),
        .bpp = f.bpp,
        .red_shift = f.red_shift,
        .green_shift = f.green_shift,
        .blue_shift = f.blue_shift,
        .reserved = 0,
    };

    const pml4 = vmm.currentCr3();
    const src: [*]const u8 = @ptrCast(&info);
    validate.copyToUser(pml4, info_ptr, src[0..@sizeOf(FbInfo)], @sizeOf(FbInfo)) catch {
        return EFAULT;
    };
    return 0;
}

/// Map the framebuffer into the caller. Requires fb_acquire first.
fn sysFbMap() i64 {
    const t = sched.currentTask() orelse return EIO;
    if (fb_owner != t.ownerId()) return -13; // EACCES
    const space = t.user_space orelse return EFAULT;

    const f = framebuffer.get() orelse return -19;

    const phys = pmm.virtToPhys(@intFromPtr(f.base));
    const size = std.mem.alignForward(usize, f.pitch * f.height, vmm.PAGE_SIZE);

    // A failed mapping rolls back with a shootdown, which needs interrupts.
    io.sti();
    defer io.cli();
    const base = space.mapBorrowed(
        phys,
        size,
        vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE | vmm.WRITE_THROUGH,
        null,
    ) catch return -12;
    return @bitCast(base);
}

/// Register this port as the one the compositor serves clients on, so a
/// client message wakes the same channel input events do.
fn sysInputBind(h: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    if (fb_owner != t.ownerId()) return -13; // EACCES
    ipc.setInputSink(@bitCast(h)) catch |e| return ipcErrno(e);
    return 0;
}

/// Block until input arrives, a client message arrives, or the timeout
/// expires. Replaces a poll-and-sleep loop in the compositor, which was the
/// last thing keeping an otherwise idle desktop awake.
fn sysInputWait(timeout_ms: u64) i64 {
    const t = sched.currentTask() orelse return EIO;
    if (fb_owner != t.ownerId()) return -13; // EACCES

    io.sti();
    defer io.cli();

    const chan = event.waitChannel();
    sched.prepareWait(chan);
    // Both conditions must be checked after joining the wait queue. Checking
    // only input loses a client message sent just before this syscall: its
    // wake sees no waiter, then Peel sleeps despite the queued message.
    if (event.pending() != 0 or ipc.inputPending()) {
        sched.cancelWait();
        return 0;
    }
    sched.commitWaitTimeout(timeout_ms);
    return 0;
}

/// Drain pending input events into a user buffer. Returns the count.
fn sysInputRead(buf: u64, max: u64) i64 {
    if (max == 0) return 0;
    const want = @min(max, 64);

    var events: [64]event.Event = undefined;
    const n = event.drain(events[0..@intCast(want)]);
    if (n == 0) return 0;

    const bytes = n * @sizeOf(event.Event);
    const src: [*]const u8 = @ptrCast(&events);
    const pml4 = vmm.currentCr3();
    validate.copyToUser(pml4, buf, src[0..bytes], bytes) catch return EFAULT;
    return @intCast(n);
}

// ── Pseudo-terminals ────────────────────────────────────────────────────────

fn currentPty() ?*ipc_object.Object {
    const proc = sched.currentProcess() orelse return null;
    return proc.pty;
}

fn sysPtyCreate() i64 {
    const obj = ipc_object.createPty() catch |e| return ipcErrno(e);
    const proc = sched.currentProcess() orelse {
        ipc_object.release(obj);
        return EIO;
    };
    return proc.handles.insertOwned(obj) catch |e| {
        ipc_object.release(obj);
        return ipcErrno(e);
    };
}

/// Master side: read what the shell has written.
fn sysPtyRead(h: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    const proc = sched.currentProcess() orelse return EIO;
    const obj = proc.handles.acquire(@bitCast(h), .pty) catch |e| return ipcErrno(e);
    defer ipc_object.release(obj);

    var kbuf: [1024]u8 = undefined;
    const want = @min(len, kbuf.len);
    const n = pty_mod.masterRead(&obj.data.pty, kbuf[0..@intCast(want)]);
    if (n == 0) return 0;

    const pml4 = vmm.currentCr3();
    validate.copyToUser(pml4, buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

/// Master side: supply input the shell will read from fd 0.
fn sysPtyWrite(h: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    const proc = sched.currentProcess() orelse return EIO;
    const obj = proc.handles.acquire(@bitCast(h), .pty) catch |e| return ipcErrno(e);
    defer ipc_object.release(obj);

    var kbuf: [1024]u8 = undefined;
    const want = @min(len, kbuf.len);
    const pml4 = vmm.currentCr3();
    validate.copyFromUser(pml4, &kbuf, buf, @intCast(want)) catch return EFAULT;

    return @intCast(pty_mod.masterWrite(&obj.data.pty, kbuf[0..@intCast(want)]));
}

/// Spawn a program with its stdio bound to a PTY's slave end.
fn sysSpawnPty(path_ptr: u64, path_len: u64, h: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;

    const proc = sched.currentProcess() orelse return EIO;
    const obj = proc.handles.acquire(@bitCast(h), .pty) catch |e| return ipcErrno(e);
    defer ipc_object.release(obj);

    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(pml4, &path, path_ptr, @intCast(path_len)) catch return EFAULT;

    const tid = process.spawnPathWithPty(path[0..@intCast(path_len)], obj) catch |e| {
        return switch (e) {
            error.NotFound, error.NotMounted => ENOENT,
            error.OutOfMemory => -12,
            error.BadImage => ENOEXEC,
        };
    };
    return @intCast(tid);
}

// ── Networking ──────────────────────────────────────────────────────────────

/// Send one ICMP echo request and wait. Returns the round trip in
/// microseconds, or -EHOSTUNREACH if nothing came back.
///
/// The address arrives packed into a u32 rather than through a pointer: it is
/// four bytes, and a pointer would mean a validation round trip for no reason.
fn sysNetPing(addr: u64, seq: u64, timeout_ms: u64) i64 {
    if (!net.isUp()) return -19; // ENODEV

    const ip = [4]u8{
        @truncate(addr),
        @truncate(addr >> 8),
        @truncate(addr >> 16),
        @truncate(addr >> 24),
    };

    const us = net.ping(ip, @truncate(seq), @min(timeout_ms, 5000)) orelse return -113;
    return @intCast(us);
}

const NetInfo = extern struct {
    ip: u32,
    gateway: u32,
    netmask: u32,
    up: u32,
    mac: [6]u8,
    reserved: [2]u8,
};

fn packIp(a: [4]u8) u32 {
    return @as(u32, a[0]) | (@as(u32, a[1]) << 8) | (@as(u32, a[2]) << 16) | (@as(u32, a[3]) << 24);
}

fn sysNetInfo(out: u64) i64 {
    const mac = @import("../drivers/net/e1000.zig").macAddress();
    const info = NetInfo{
        .ip = packIp(net.local_ip),
        .gateway = packIp(net.gateway_ip),
        .netmask = packIp(net.netmask),
        .up = if (net.isUp()) 1 else 0,
        .mac = mac,
        .reserved = .{ 0, 0 },
    };
    const pml4 = vmm.currentCr3();
    const src: [*]const u8 = @ptrCast(&info);
    validate.copyToUser(pml4, out, src[0..@sizeOf(NetInfo)], @sizeOf(NetInfo)) catch return EFAULT;
    return 0;
}

/// Resolve a hostname. Returns the address packed into the low 32 bits.
fn sysNetResolve(name_ptr: u64, name_len: u64) i64 {
    if (!net.isUp()) return -19;
    if (name_len == 0 or name_len > 255) return EINVAL;

    const pml4 = vmm.currentCr3();
    var name: [256]u8 = undefined;
    validate.copyFromUser(pml4, &name, name_ptr, @intCast(name_len)) catch return EFAULT;

    const dns = @import("../net/dns.zig");
    const ip = dns.resolve(name[0..@intCast(name_len)], 3000) orelse return -2;
    return @intCast(packIp(ip));
}

fn sysUdpOpen(port: u64) i64 {
    if (!net.isUp()) return -19;
    if (port > std.math.maxInt(u16)) return EINVAL;
    const task = sched.currentTask() orelse return EIO;
    const idx = net.socketOpenOwned(@intCast(port), task.ownerId()) orelse return EMFILE;
    return @intCast(idx);
}

fn sysUdpSend(sock: u64, dst: u64, port: u64, buf_and_len: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!net.socketOwnedBy(@intCast(sock), task.ownerId())) return EBADF;
    // Pointer in the low 48 bits, length in the top 16. Six arguments is one
    // more than the syscall ABI has registers to spare here.
    const ptr = buf_and_len & 0x0000_FFFF_FFFF_FFFF;
    const len = buf_and_len >> 48;
    if (len > net.MAX_DATAGRAM) return EMSGSIZE;

    const pml4 = vmm.currentCr3();
    var kbuf: [net.MAX_DATAGRAM]u8 = undefined;
    validate.copyFromUser(pml4, &kbuf, ptr, @intCast(len)) catch return EFAULT;

    const ip = [4]u8{
        @truncate(dst), @truncate(dst >> 8), @truncate(dst >> 16), @truncate(dst >> 24),
    };
    net.sendTo(@intCast(sock), ip, @truncate(port), kbuf[0..@intCast(len)]) catch return EIO;
    return @intCast(len);
}

fn sysUdpRecv(sock: u64, buf: u64, len: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!net.socketOwnedBy(@intCast(sock), task.ownerId())) return EBADF;
    var d: net.Datagram = undefined;
    if (!net.pollReceive(@intCast(sock), &d)) return EAGAIN;

    const n = @min(len, d.len);
    const pml4 = vmm.currentCr3();
    validate.copyToUser(pml4, buf, d.data[0..@intCast(n)], @intCast(n)) catch return EFAULT;
    return @intCast(n);
}

fn sysUdpClose(sock: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!net.socketOwnedBy(@intCast(sock), task.ownerId())) return EBADF;
    net.socketClose(@intCast(sock));
    return 0;
}

const tcp = @import("../net/tcp.zig");

fn tcpErrno(e: tcp.Error) i64 {
    return switch (e) {
        tcp.Error.NoSockets => EMFILE,
        tcp.Error.NotConnected => -107, // ENOTCONN
        tcp.Error.Refused => -111, // ECONNREFUSED
        tcp.Error.Timeout => -110, // ETIMEDOUT
        tcp.Error.TooLarge => EMSGSIZE,
        tcp.Error.Reset => -104, // ECONNRESET
    };
}

fn sysTcpConnect(addr: u64, port: u64, timeout_ms: u64) i64 {
    if (!net.isUp()) return -19;
    if (port > std.math.maxInt(u16)) return EINVAL;
    const task = sched.currentTask() orelse return EIO;
    const ip = [4]u8{
        @truncate(addr), @truncate(addr >> 8), @truncate(addr >> 16), @truncate(addr >> 24),
    };
    const idx = tcp.connect(ip, @intCast(port), @min(timeout_ms, 10_000), task.ownerId()) catch |e| {
        return tcpErrno(e);
    };
    return @intCast(idx);
}

fn sysTcpSend(sock: u64, buf: u64, len: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!tcp.ownedBy(@intCast(sock), task.ownerId())) return EBADF;
    if (len == 0) return 0;
    if (len > 1400) return EMSGSIZE;

    const pml4 = vmm.currentCr3();
    var kbuf: [1400]u8 = undefined;
    validate.copyFromUser(pml4, &kbuf, buf, @intCast(len)) catch return EFAULT;

    const n = tcp.send(@intCast(sock), kbuf[0..@intCast(len)]) catch |e| return tcpErrno(e);
    return @intCast(n);
}

fn sysTcpRecv(sock: u64, buf: u64, len: u64, timeout_ms: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!tcp.ownedBy(@intCast(sock), task.ownerId())) return EBADF;
    if (len == 0) return 0;

    var kbuf: [2048]u8 = undefined;
    const want = @min(len, kbuf.len);
    const n = tcp.recv(@intCast(sock), kbuf[0..@intCast(want)], @min(timeout_ms, 10_000)) catch |e| {
        return tcpErrno(e);
    };
    if (n == 0) return 0;

    const pml4 = vmm.currentCr3();
    validate.copyToUser(pml4, buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

fn sysTcpClose(sock: u64) i64 {
    const task = sched.currentTask() orelse return EIO;
    if (!tcp.ownedBy(@intCast(sock), task.ownerId())) return EBADF;
    tcp.close(@intCast(sock));
    return 0;
}

fn sysGetpid() i64 {
    const t = sched.currentTask() orelse return -1;
    return @intCast(t.ownerId());
}

fn sysYield() i64 {
    sched.yield();
    return 0;
}

fn sysUptime() i64 {
    const time = @import("../time/time.zig");
    return @intCast(time.millisSinceBoot());
}

pub fn count() u64 {
    return syscall_count;
}
