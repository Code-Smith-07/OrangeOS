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
const serial = @import("../drivers/char/serial.zig");
const io = @import("../arch/x86_64/io.zig");
const process = @import("../sched/process.zig");
const citrusfs = @import("../fs/citrusfs/citrusfs.zig");

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
    yield = 7,
    spawn = 8,
    wait = 9,
    open = 20,
    close = 21,
    read = 22,
    readdir = 34,
    uptime = 60,
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

var syscall_count: u64 = 0;

/// The single entry point from assembly.
export fn syscallDispatch(frame: *SyscallFrame) callconv(.c) void {
    syscall_count += 1;

    // Arguments: rdi, rsi, rdx, r10, r8, r9. Note r10, not rcx — the syscall
    // instruction clobbers rcx with the return address.
    const result: i64 = switch (@as(Nr, @enumFromInt(frame.rax))) {
        .exit => sysExit(@bitCast(frame.rdi)),
        .write => sysWrite(frame.rdi, frame.rsi, frame.rdx),
        .getpid => sysGetpid(),
        .open => sysOpen(frame.rdi, frame.rsi),
        .close => sysClose(frame.rdi),
        .read => sysRead(frame.rdi, frame.rsi, frame.rdx),
        .spawn => sysSpawn(frame.rdi, frame.rsi),
        .wait => sysWait(frame.rdi),
        // Fourth argument is in r10, not rcx: the syscall instruction
        // clobbers rcx with the return address.
        .readdir => sysReaddir(frame.rdi, frame.rsi, frame.rdx, frame.r10),
        .yield => sysYield(),
        .uptime => sysUptime(),
        else => ENOSYS,
    };

    frame.rax = @bitCast(result);
}

fn sysExit(code: i64) i64 {
    sched.exit(@truncate(code));
}

fn sysWrite(fd: u64, buf: u64, len: u64) i64 {
    if (fd != 1 and fd != 2) return EBADF;
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;

    const pml4 = vmm.currentCr3();

    var kbuf: [4096]u8 = undefined;
    validate.copyFromUser(pml4, &kbuf, buf, @intCast(len)) catch return EFAULT;

    console.write(kbuf[0..@intCast(len)]);
    return @intCast(len);
}

/// Map a VFS error onto the ABI's errno values.
fn vfsErrno(e: vfs.Error) i64 {
    return switch (e) {
        vfs.Error.NotFound, vfs.Error.NotMounted => ENOENT,
        vfs.Error.NotDirectory, vfs.Error.NotFile => EISDIR,
        vfs.Error.NameTooLong => ENAMETOOLONG,
        vfs.Error.TooManyOpen => EMFILE,
        vfs.Error.BadFd => EBADF,
        vfs.Error.IoError => EIO,
    };
}

fn sysOpen(path_ptr: u64, path_len: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;

    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(pml4, &path, path_ptr, @intCast(path_len)) catch return EFAULT;

    const fd = vfs.open(path[0..@intCast(path_len)]) catch |e| return vfsErrno(e);
    return fd;
}

fn sysClose(fd: u64) i64 {
    vfs.close(@intCast(@as(i64, @bitCast(fd)))) catch |e| return vfsErrno(e);
    return 0;
}

fn sysRead(fd: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    if (len > 4096) return EFAULT;

    const pml4 = vmm.currentCr3();

    // fd 0 is the console. Block until at least one byte is available, then
    // return what is there rather than waiting for the full request: a shell
    // wants each keystroke as it arrives, not a full buffer.
    if (fd == 0) {
        var kbuf: [256]u8 = undefined;
        const want = @min(len, kbuf.len);

        // MSR_FMASK clears IF on syscall entry, so we arrive with interrupts
        // disabled. That is right for the fast path, but a blocking read has
        // to re-enable them: the bytes we are waiting for arrive via the
        // serial RX interrupt, so spinning with IF clear waits forever.
        io.sti();
        defer io.cli();

        var n: usize = 0;
        while (n == 0) {
            while (n < want) {
                const c = serial.readByte() orelse break;
                kbuf[n] = c;
                n += 1;
            }
            if (n == 0) sched.yield();
        }

        validate.copyToUser(pml4, buf, kbuf[0..n], n) catch return EFAULT;
        return @intCast(n);
    }

    // Read into kernel memory first, then copy out. Reading straight into the
    // user buffer would mean the filesystem writing through an unvalidated
    // pointer.
    var kbuf: [4096]u8 = undefined;
    const n = vfs.read(@intCast(@as(i64, @bitCast(fd))), kbuf[0..@intCast(len)]) catch |e| {
        return vfsErrno(e);
    };

    validate.copyToUser(pml4, buf, kbuf[0..n], n) catch return EFAULT;
    return @intCast(n);
}

const ECHILD: i64 = -10;
const ENOEXEC: i64 = -8;

fn sysSpawn(path_ptr: u64, path_len: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;

    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(pml4, &path, path_ptr, @intCast(path_len)) catch return EFAULT;

    const tid = process.spawnPath(path[0..@intCast(path_len)]) catch |e| {
        return switch (e) {
            error.NotFound, error.NotMounted => ENOENT,
            error.OutOfMemory => -12,
            error.BadImage => ENOEXEC,
            else => EIO,
        };
    };
    return @intCast(tid);
}

/// Wait for a task to become a zombie and return its exit code.
///
/// Polls via yield rather than a wait queue. A proper implementation blocks
/// the parent and has exit() wake it; that needs per-process parent tracking,
/// which arrives with fork in Phase 6b.
fn sysWait(pid: u64) i64 {
    const tid: u32 = @truncate(pid);
    const t = sched.findByTid(tid) orelse return ECHILD;

    // Same reason as sysRead: we arrive with IF clear, and the child needs
    // timer interrupts to be scheduled at all.
    io.sti();
    defer io.cli();

    while (t.state != .zombie) {
        sched.yield();
    }
    return t.exit_code;
}

/// One entry as handed to userspace. Must match pulp.DirEntry.
const UserDirEntry = extern struct {
    inode: u32,
    type: u8,
    name_len: u8,
    name: [128]u8,
};

const ReaddirCtx = struct {
    entries: [32]UserDirEntry = undefined,
    count: usize = 0,
    max: usize = 0,
};

fn collectEntry(ctx_ptr: *anyopaque, name: []const u8, ino: u32, dtype: u8) bool {
    const ctx: *ReaddirCtx = @ptrCast(@alignCast(ctx_ptr));
    if (ctx.count >= ctx.max or ctx.count >= ctx.entries.len) return false;
    if (name.len > 128) return true;

    var e = &ctx.entries[ctx.count];
    e.inode = ino;
    e.type = dtype;
    e.name_len = @intCast(name.len);
    @memcpy(e.name[0..name.len], name);
    ctx.count += 1;
    return true;
}

fn sysReaddir(path_ptr: u64, path_len: u64, out: u64, max: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;
    if (max == 0) return 0;

    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(pml4, &path, path_ptr, @intCast(path_len)) catch return EFAULT;

    var ctx = ReaddirCtx{ .max = @min(max, 32) };
    vfs.iterateDir(path[0..@intCast(path_len)], &ctx, collectEntry) catch |e| {
        return vfsErrno(e);
    };

    const bytes = ctx.count * @sizeOf(UserDirEntry);
    const src: [*]const u8 = @ptrCast(&ctx.entries);
    validate.copyToUser(pml4, out, src[0..bytes], bytes) catch return EFAULT;

    return @intCast(ctx.count);
}

fn sysGetpid() i64 {
    const t = sched.currentTask() orelse return -1;
    return @intCast(t.tid);
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
