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
    yield = 7,
    spawn = 8,
    wait = 9,
    sleep_ms = 61,
    open = 20,
    close = 21,
    read = 22,
    readdir = 34,
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
    shm_map = 55,
    handle_close = 56,
    fb_acquire = 70,
    fb_map = 71,
    input_read = 72,
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
        .wait => sysWait(frame.rdi, frame.rsi),
        .sleep_ms => sysSleepMs(frame.rdi),
        // Fourth argument is in r10, not rcx: the syscall instruction
        // clobbers rcx with the return address.
        .readdir => sysReaddir(frame.rdi, frame.rsi, frame.rdx, frame.r10),
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
        .shm_map => sysShmMap(frame.rdi, frame.rsi),
        .handle_close => sysHandleClose(frame.rdi),
        .fb_acquire => sysFbAcquire(frame.rdi),
        .fb_map => sysFbMap(),
        .input_read => sysInputRead(frame.rdi, frame.rsi),
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

    // A task with a PTY writes into it rather than to the console. That is
    // what puts a shell's output in a terminal window without the shell
    // knowing anything about windows.
    if (currentPty()) |obj| {
        return @intCast(pty_mod.slaveWrite(&obj.data.pty, kbuf[0..@intCast(len)]));
    }

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

        // Bound to a PTY: block on that instead of the serial line.
        if (currentPty()) |obj| {
            io.sti();
            defer io.cli();

            var n: usize = 0;
            while (n == 0) {
                n = pty_mod.slaveRead(&obj.data.pty, kbuf[0..@intCast(want)]);
                if (n == 0) sched.yield();
            }
            validate.copyToUser(pml4, buf, kbuf[0..n], n) catch return EFAULT;
            return @intCast(n);
        }

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
/// `flags` bit 0 is WNOHANG: return -EAGAIN immediately if the task is still
/// running. A supervisor with more than one service needs this — blocking on
/// each in turn means a long-running service prevents noticing that any other
/// one died.
pub const WNOHANG: u64 = 1;

fn sysWait(pid: u64, flags: u64) i64 {
    const tid: u32 = @truncate(pid);
    const t = sched.findByTid(tid) orelse return ECHILD;

    if (flags & WNOHANG != 0) {
        if (t.state != .zombie) return EAGAIN;
        return t.exit_code;
    }

    // We arrive with IF clear, and the child needs timer interrupts to be
    // scheduled at all.
    io.sti();
    defer io.cli();

    while (t.state != .zombie) {
        sched.yield();
    }
    return t.exit_code;
}

/// Sleep for `ms` milliseconds. Yields rather than spinning, so other work
/// runs while a supervisor is idle between polls.
fn sysSleepMs(ms: u64) i64 {
    if (ms == 0) {
        sched.yield();
        return 0;
    }
    io.sti();
    defer io.cli();

    const time = @import("../time/time.zig");
    const deadline = time.monotonicNs() + ms * 1_000_000;
    while (time.monotonicNs() < deadline) {
        sched.yield();
    }
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
    if (fb_owner != 0 and fb_owner != t.tid) return -16; // EBUSY
    fb_owner = t.tid;

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
    if (fb_owner != t.tid) return -13; // EACCES

    const f = framebuffer.get() orelse return -19;

    const phys = pmm.virtToPhys(@intFromPtr(f.base));
    const size = std.mem.alignForward(usize, f.pitch * f.height, vmm.PAGE_SIZE);

    const base = t.shm_next;
    var off: usize = 0;
    while (off < size) : (off += vmm.PAGE_SIZE) {
        vmm.mapPage(
            t.address_space,
            base + off,
            phys + off,
            vmm.PRESENT | vmm.WRITABLE | vmm.USER | vmm.NO_EXECUTE | vmm.WRITE_THROUGH,
        ) catch return -12;
        vmm.invalidatePage(base + off);
    }
    t.shm_next = base + size + vmm.PAGE_SIZE;

    return @bitCast(base);
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
    const t = sched.currentTask() orelse return null;
    const p = t.pty orelse return null;
    return @ptrCast(@alignCast(p));
}

fn sysPtyCreate() i64 {
    const obj = ipc_object.createPty() catch |e| return ipcErrno(e);
    const t = sched.currentTask() orelse return EIO;
    return t.handles.insert(obj) catch |e| ipcErrno(e);
}

/// Master side: read what the shell has written.
fn sysPtyRead(h: u64, buf: u64, len: u64) i64 {
    if (len == 0) return 0;
    const t = sched.currentTask() orelse return EIO;
    const obj = t.handles.getPty(@bitCast(h)) catch |e| return ipcErrno(e);

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
    const t = sched.currentTask() orelse return EIO;
    const obj = t.handles.getPty(@bitCast(h)) catch |e| return ipcErrno(e);

    var kbuf: [1024]u8 = undefined;
    const want = @min(len, kbuf.len);
    const pml4 = vmm.currentCr3();
    validate.copyFromUser(pml4, &kbuf, buf, @intCast(want)) catch return EFAULT;

    return @intCast(pty_mod.masterWrite(&obj.data.pty, kbuf[0..@intCast(want)]));
}

/// Spawn a program with its stdio bound to a PTY's slave end.
fn sysSpawnPty(path_ptr: u64, path_len: u64, h: u64) i64 {
    if (path_len == 0 or path_len > vfs.MAX_PATH) return ENAMETOOLONG;

    const t = sched.currentTask() orelse return EIO;
    const obj = t.handles.getPty(@bitCast(h)) catch |e| return ipcErrno(e);

    const pml4 = vmm.currentCr3();
    var path: [vfs.MAX_PATH]u8 = undefined;
    validate.copyFromUser(pml4, &path, path_ptr, @intCast(path_len)) catch return EFAULT;

    const tid = process.spawnPathWithPty(path[0..@intCast(path_len)], obj) catch |e| {
        return switch (e) {
            error.NotFound, error.NotMounted => ENOENT,
            error.OutOfMemory => -12,
            error.BadImage => ENOEXEC,
            else => EIO,
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
