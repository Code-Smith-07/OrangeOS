//! OrangeOS system layer beneath musl.
//!
//! musl implements POSIX on top of Linux-numbered system calls. OrangeOS keeps
//! its own kernel ABI, so every musl system call arrives here instead (see
//! arch/syscall_arch.h) and is translated onto native OrangeOS calls. Requests
//! with no OrangeOS meaning return -ENOSYS rather than a fabricated success;
//! the few answered without the kernel are ones that are genuinely no-ops here
//! (masking signals that can never be delivered, advisory hints).
//!
//! This file also replaces musl's x86-64 assembly that executes `syscall`
//! directly: thread creation, the thread pointer, cancellable system calls
//! and a detached thread unmapping its own stack.
//!
//! SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

// ── Native OrangeOS calls ───────────────────────────────────────────────────

const OR = struct {
    const exit = 0;
    const write = 1;
    const getpid = 4;
    const getppid = 5;
    const yield = 7;
    const mmap = 10;
    const munmap = 11;
    const mprotect = 12;
    const tls_set_base = 16;
    const tls_get_base = 17;
    const user_wait = 18;
    const user_wake = 19;
    const open = 20;
    const close = 21;
    const read = 22;
    const seek = 24;
    const stat = 25;
    const fstat = 26;
    const mkdir = 30;
    const rmdir = 31;
    const unlink = 32;
    const rename = 33;
    const ftruncate = 120;
    const readdir_fd = 121;
    const statfs = 122;
    const pread = 123;
    const pwrite = 124;
    const pipe = 130;
    const dup = 131;
    const fd_control = 132;
    const eventfd = 133;
    const epoll_create = 134;
    const epoll_ctl = 135;
    const epoll_wait = 136;
    const poll = 137;
    const socketpair = 138;
    const sendmsg = 139;
    const recvmsg = 140;
    const shutdown = 141;
    const inet_socket = 157;
    const connect = 158;
    const bind = 159;
    const listen = 160;
    const sockname = 161;
    const getsockopt = 162;
    const setsockopt = 163;
    const fs_sync = 164;
    const wait = 9;
    const chdir = 35;
    const getcwd = 36;
    const resolve_path = 142;
    const spawn_process = 143;
    const vm_map = 144;
    const vm_advise = 145;
    const vm_remap = 146;
    const memfd = 147;
    const getrandom = 148;
    const sigaction = 150;
    const sigmask = 151;
    const kill = 152;
    const tkill = 153;
    const sigaltstack = 155;
    const sigpending = 156;
    const thread_create = 40;
    const thread_exit = 41;
    const gettid = 45;
    const set_exit_word = 46;
    const sleep_ms = 61;
    const clock_ns = 63;
};

inline fn raw(nr: u64, a: u64, b: u64, c: u64, d: u64, e: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
          [d] "{r10}" (d),
          [e] "{r8}" (e),
        : "rcx", "r11", "memory"
    );
}

inline fn raw6(nr: u64, a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
          [d] "{r10}" (d),
          [e] "{r8}" (e),
          [f] "{r9}" (f),
        : "rcx", "r11", "memory"
    );
}

inline fn raw0(nr: u64) i64 {
    return raw(nr, 0, 0, 0, 0, 0);
}

inline fn raw1(nr: u64, a: u64) i64 {
    return raw(nr, a, 0, 0, 0, 0);
}

inline fn raw2(nr: u64, a: u64, b: u64) i64 {
    return raw(nr, a, b, 0, 0, 0);
}

inline fn raw3(nr: u64, a: u64, b: u64, c: u64) i64 {
    return raw(nr, a, b, c, 0, 0);
}

// ── Linux numbers and constants musl uses ───────────────────────────────────

const SYS = struct {
    const read = 0;
    const write = 1;
    const open = 2;
    const close = 3;
    const stat = 4;
    const fstat = 5;
    const lstat = 6;
    const lseek = 8;
    const mmap = 9;
    const mprotect = 10;
    const munmap = 11;
    const brk = 12;
    const rt_sigaction = 13;
    const rt_sigprocmask = 14;
    const ioctl = 16;
    const poll = 7;
    const select = 23;
    const socket = 41;
    const sendto = 44;
    const recvfrom = 45;
    const sendmsg = 46;
    const recvmsg = 47;
    const shutdown = 48;
    const socketpair = 53;
    const connect = 42;
    const accept = 43;
    const bind = 49;
    const listen = 50;
    const getsockname = 51;
    const getpeername = 52;
    const setsockopt = 54;
    const getsockopt = 55;
    const accept4 = 288;
    const wait4 = 61;
    const kill = 62;
    const rt_sigpending = 127;
    const sigaltstack = 131;
    const tkill = 200;
    const tgkill = 234;
    const chdir = 80;
    const fchdir = 81;
    const memfd_create = 319;
    const getrandom = 318;
    const epoll_create = 213;
    const epoll_wait = 232;
    const epoll_ctl = 233;
    const pselect6 = 270;
    const ppoll = 271;
    const epoll_pwait = 281;
    const epoll_create1 = 291;
    const epoll_pwait2 = 441;
    const pipe = 22;
    const dup = 32;
    const dup2 = 33;
    const eventfd = 284;
    const eventfd2 = 290;
    const dup3 = 292;
    const pipe2 = 293;
    const pread64 = 17;
    const pwrite64 = 18;
    const readv = 19;
    const writev = 20;
    const access = 21;
    const sched_yield = 24;
    const mremap = 25;
    const madvise = 28;
    const nanosleep = 35;
    const getpid = 39;
    const exit = 60;
    const uname = 63;
    const fcntl = 72;
    const getcwd = 79;
    const rename = 82;
    const mkdir = 83;
    const rmdir = 84;
    const unlink = 87;
    const fsync = 74;
    const fdatasync = 75;
    const truncate = 76;
    const ftruncate = 77;
    const statfs = 137;
    const sync = 162;
    const syncfs = 306;
    const getdents64 = 217;
    const mkdirat = 258;
    const unlinkat = 263;
    const renameat = 264;
    const renameat2 = 316;
    const gettimeofday = 96;
    const getuid = 102;
    const getgid = 104;
    const geteuid = 107;
    const getegid = 108;
    const getppid = 110;
    const arch_prctl = 158;
    const gettid = 186;
    const time = 201;
    const futex = 202;
    const set_tid_address = 218;
    const clock_gettime = 228;
    const clock_getres = 229;
    const clock_nanosleep = 230;
    const exit_group = 231;
    const openat = 257;
    const newfstatat = 262;
    const faccessat = 269;
    const prlimit64 = 302;
    const statx = 332;
    const faccessat2 = 439;
    const chmod = 90;
    const fchmod = 91;
    const fchmodat = 268;
    const fchmodat2 = 452;
};

const E = struct {
    const PERM = 1;
    const NOENT = 2;
    const INTR = 4;
    const BADF = 9;
    const AGAIN = 11;
    const NOMEM = 12;
    const ACCES = 13;
    const FAULT = 14;
    const EXIST = 17;
    const NOTDIR = 20;
    const INVAL = 22;
    const NOTTY = 25;
    const SPIPE = 29;
    const ROFS = 30;
    const NOSYS = 38;
    const NAMETOOLONG = 36;
    const OPNOTSUPP = 95;
    const TIMEDOUT = 110;
};

fn err(code: i64) i64 {
    return -code;
}

const AT_FDCWD: i64 = -100;
const AT_EMPTY_PATH: u64 = 0x1000;
const AT_REMOVEDIR: u64 = 0x200;
const O_ACCMODE: u64 = 3;
const O_WRONLY: u64 = 1;
const O_RDWR: u64 = 2;
const O_CREAT: u64 = 0o100;
const O_EXCL: u64 = 0o200;
const O_TRUNC: u64 = 0o1000;
const O_APPEND: u64 = 0o2000;
const O_DIRECTORY: u64 = 0o200000;
const O_NONBLOCK: u64 = 0o4000;
const O_CLOEXEC: u64 = 0o2000000;
/// O_TMPFILE without its O_DIRECTORY bit.
const O_TMPFILE_ONLY: u64 = 0o20000000;

/// Native open() flags.
const OPEN_READ: u64 = 1;
const OPEN_WRITE: u64 = 2;
const OPEN_CREATE: u64 = 4;
const OPEN_EXCLUSIVE: u64 = 8;
const OPEN_TRUNCATE: u64 = 16;
const OPEN_APPEND: u64 = 32;
const OPEN_DIRECTORY: u64 = 64;
const OPEN_NONBLOCK: u64 = 128;
const OPEN_CLOEXEC: u64 = 256;
/// Flags of the native pipe, dup and eventfd calls.
const FD_NONBLOCK: u64 = 1;
const FD_CLOEXEC: u64 = 2;
const EFD_SEMAPHORE: u64 = 4;

/// O_NONBLOCK/O_CLOEXEC (as pipe2, eventfd2 and dup3 take them) to native.
fn fdFlags(flags: u64) u64 {
    return (if (flags & O_NONBLOCK != 0) FD_NONBLOCK else 0) | (if (flags & O_CLOEXEC != 0) FD_CLOEXEC else 0);
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn cString(address: u64) ?[]const u8 {
    if (address == 0) return null;
    const pointer: [*:0]const u8 = @ptrFromInt(address);
    return std.mem.span(pointer);
}

/// A path argument of an *at() call, or a negative errno. Relative to a
/// directory descriptor, the kernel resolves it to an absolute path first.
fn pathAt(dirfd: i64, address: u64, buffer: *[256]u8) union(enum) { path: []const u8, errno: i64 } {
    const path = cString(address) orelse return .{ .errno = err(E.FAULT) };
    if (path.len == 0) return .{ .errno = err(E.NOENT) };
    if (path.len > buffer.len) return .{ .errno = err(E.NAMETOOLONG) };
    // Absolute paths, and relative ones from the working directory, go to
    // the kernel as they are; relative to a directory descriptor, the kernel
    // resolves them first.
    if (path[0] == '/' or dirfd == AT_FDCWD) return .{ .path = path };
    const len = raw(OR.resolve_path, @bitCast(dirfd), @intFromPtr(path.ptr), path.len, @intFromPtr(buffer), buffer.len);
    if (len < 0) return .{ .errno = len };
    return .{ .path = buffer[0..@intCast(len)] };
}

fn pathCall(nr: u64, dirfd: i64, address: u64) i64 {
    var buffer: [256]u8 = undefined;
    return switch (pathAt(dirfd, address, &buffer)) {
        .path => |path| raw2(nr, @intFromPtr(path.ptr), path.len),
        .errno => |code| code,
    };
}

fn renamePath(from_dirfd: i64, from: u64, to_dirfd: i64, to: u64) i64 {
    var source_buffer: [256]u8 = undefined;
    var target_buffer: [256]u8 = undefined;
    const source = switch (pathAt(from_dirfd, from, &source_buffer)) {
        .path => |path| path,
        .errno => |code| return code,
    };
    const target = switch (pathAt(to_dirfd, to, &target_buffer)) {
        .path => |path| path,
        .errno => |code| return code,
    };
    return raw(OR.rename, @intFromPtr(source.ptr), source.len, @intFromPtr(target.ptr), target.len, 0);
}

/// `mode` is the descriptor's access (fstat) or, for a path (stat), whether
/// its filesystem is writable: native OPEN_READ/WRITE/APPEND bits.
const Status = extern struct { size: u64, kind: u32, mode: u32 };

const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;
const S_IFCHR: u32 = 0o020000;
const S_IFIFO: u32 = 0o010000;
const S_IFSOCK: u32 = 0o140000;

/// Native kinds: 1 file, 2 directory, 3 console, 4 pipe, 5 socket,
/// 6 anonymous (eventfd, epoll), which Linux reports with no type bits,
/// 7 device (/dev/null, /dev/urandom, ...).
fn modeOf(kind: u32) u32 {
    return switch (kind) {
        2 => S_IFDIR | 0o755,
        3 => S_IFCHR | 0o620,
        4 => S_IFIFO | 0o600,
        5 => S_IFSOCK | 0o777,
        6 => 0o600,
        7 => S_IFCHR | 0o666,
        else => S_IFREG | 0o644,
    };
}

fn statusOf(dirfd: i64, path_address: u64, flags: u64, out: *Status) i64 {
    const path = cString(path_address) orelse "";
    if (path.len == 0) {
        if (flags & AT_EMPTY_PATH == 0) return err(E.NOENT);
        return raw2(OR.fstat, @bitCast(dirfd), @intFromPtr(out));
    }
    var buffer: [256]u8 = undefined;
    return switch (pathAt(dirfd, path_address, &buffer)) {
        .path => |full| raw3(OR.stat, @intFromPtr(full.ptr), full.len, @intFromPtr(out)),
        .errno => |code| code,
    };
}

/// The chmod family. OrangeOS has one user and keeps no permission bits:
/// every file reports the mode modeOf gives its kind. Asking for that mode
/// changes nothing and succeeds; any other mode is refused with EPERM, and
/// a read-only filesystem refuses with EROFS, as Linux does for filesystems
/// without mode bits.
fn changeMode(dirfd: i64, path_address: u64, flags: u64, mode: u64) i64 {
    var status: Status = undefined;
    const r = statusOf(dirfd, path_address, flags, &status);
    if (r < 0) return r;
    const by_path = path_address != 0 and (cString(path_address) orelse "").len != 0;
    if (by_path and status.mode & OPEN_WRITE == 0) return err(E.ROFS);
    if (mode & 0o7777 != modeOf(status.kind) & 0o7777) return err(E.PERM);
    return 0;
}

/// Linux `struct stat` for x86-64 (musl's kstat).
const KStat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 1,
    mode: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    pad0: u32 = 0,
    rdev: u64 = 0,
    size: i64,
    blksize: i64 = 4096,
    blocks: i64,
    times: [6]i64 = [_]i64{0} ** 6,
    unused: [3]i64 = [_]i64{0} ** 3,
};

fn fillKStat(address: u64, status: Status) void {
    const out: *KStat = @ptrFromInt(address);
    out.* = .{ .mode = modeOf(status.kind), .size = @intCast(status.size), .blocks = @intCast((status.size + 511) / 512) };
}

/// Linux `struct statx`.
const StatxTime = extern struct { sec: i64 = 0, nsec: u32 = 0, reserved: i32 = 0 };
const Statx = extern struct {
    mask: u32,
    blksize: u32,
    attributes: u64 = 0,
    nlink: u32,
    uid: u32 = 0,
    gid: u32 = 0,
    mode: u16,
    spare0: u16 = 0,
    ino: u64 = 0,
    size: u64,
    blocks: u64,
    attributes_mask: u64 = 0,
    atime: StatxTime = .{},
    btime: StatxTime = .{},
    ctime: StatxTime = .{},
    mtime: StatxTime = .{},
    rdev_major: u32 = 0,
    rdev_minor: u32 = 0,
    dev_major: u32 = 0,
    dev_minor: u32 = 0,
    spare: [14]u64 = [_]u64{0} ** 14,
};

const Timespec = extern struct { sec: i64, nsec: i64 };

fn clockNs(clock: u64) ?u64 {
    const r = raw1(OR.clock_ns, clock);
    return if (r < 0) null else @intCast(r);
}

/// Linux clock ids: realtime ones read the wall clock, the others the
/// monotonic clock. CPU-time clocks have no OrangeOS source yet.
fn readClock(id: i64) ?u64 {
    return switch (id) {
        0, 5, 8 => clockNs(1),
        1, 4, 6, 7, 9 => clockNs(0),
        else => null,
    };
}

fn sleepNs(ns: u64) void {
    if (ns == 0) {
        _ = raw0(OR.yield);
        return;
    }
    _ = raw1(OR.sleep_ms, (ns + 999_999) / 1_000_000);
}

/// Sleep, or return -EINTR when a caught signal cuts it short, with the time
/// left written to `remaining` (a timespec) when given.
fn sleepInterruptible(ns: u64, remaining: u64) i64 {
    if (ns == 0) {
        _ = raw0(OR.yield);
        return 0;
    }
    const start = clockNs(0) orelse 0;
    const r = raw1(OR.sleep_ms, (ns + 999_999) / 1_000_000);
    if (r != err(E.INTR)) return 0;
    if (remaining != 0) {
        const elapsed = (clockNs(0) orelse start) - start;
        const left = ns -| elapsed;
        @as(*Timespec, @ptrFromInt(remaining)).* = .{ .sec = @intCast(left / 1_000_000_000), .nsec = @intCast(left % 1_000_000_000) };
    }
    return r;
}

const Iovec = extern struct { base: u64, len: u64 };

fn vectored(nr: u64, fd: u64, vec: u64, count: u64) i64 {
    if (count > 1024) return err(E.INVAL);
    const iov: [*]const Iovec = @ptrFromInt(vec);
    var total: i64 = 0;
    for (iov[0..count]) |v| {
        if (v.len == 0) continue;
        const r = raw3(nr, fd, v.base, @min(v.len, 4096));
        if (r < 0) return if (total > 0) total else r;
        total += r;
        // A short transfer ends the call, as it does for readv/writev.
        if (@as(u64, @intCast(r)) < v.len) break;
    }
    return total;
}

// ── Socket pairs and descriptor passing ─────────────────────────────────────

const AF_UNIX = 1;
const AF_INET = 2;
const SOCK_TYPE_MASK: u64 = 0xf;
const SOCK_NONBLOCK: u64 = 0o4000;
const SOCK_CLOEXEC: u64 = 0o2000000;
const MSG_DONTWAIT: u64 = 0x40;
const MSG_PEEK: u64 = 0x2;
const MSG_TRUNC_REQUEST: u64 = 0x20;
const MSG_NOSIGNAL: u64 = 0x4000;
const MSG_CMSG_CLOEXEC: u64 = 0x40000000;
const MSG_CTRUNC: u32 = 0x8;
const MSG_TRUNC: u32 = 0x20;
const SOL_SOCKET = 1;
const SCM_RIGHTS = 1;
const MAX_RIGHTS = 64;

/// Linux struct msghdr.
const MsgHeader = extern struct {
    name: u64 = 0,
    namelen: u32 = 0,
    pad0: u32 = 0,
    iov: u64 = 0,
    iovlen: u64 = 0,
    control: u64 = 0,
    controllen: u64 = 0,
    flags: u32 = 0,
    pad1: u32 = 0,
};
/// struct cmsghdr, then data aligned to 8 bytes.
const CMSG_HEADER = 16;

/// The native message (see the kernel's sendmsg/recvmsg). Addresses are in
/// Linux's sockaddr_in layout, which the kernel takes as it is.
const NativeMessage = extern struct {
    iov: u64,
    iov_count: u64,
    fds: u64,
    fd_count: u32,
    flags: u32,
    name: u64 = 0,
    name_len: u32 = 0,
    reserved: u32 = 0,
};

/// socket(): AF_INET stream (TCP) and datagram (UDP) sockets. IPv6 and named
/// local sockets are not offered (socketpair covers local ones).
fn socket(domain: u64, kind: u64, protocol: u64) i64 {
    if (domain != AF_INET) return err(97); // EAFNOSUPPORT
    const base = kind & SOCK_TYPE_MASK;
    if (kind & ~(SOCK_TYPE_MASK | SOCK_NONBLOCK | SOCK_CLOEXEC) != 0) return err(E.INVAL);
    const flags = (if (kind & SOCK_NONBLOCK != 0) FD_NONBLOCK else 0) | (if (kind & SOCK_CLOEXEC != 0) FD_CLOEXEC else 0);
    return raw(OR.inet_socket, domain, base, protocol, flags, 0);
}

/// accept(): nothing can listen, so nothing can be accepted.
fn accept(fd: u64) i64 {
    var status: Status = undefined;
    const r = raw2(OR.fstat, fd, @intFromPtr(&status));
    if (r < 0) return r;
    return if (status.kind == 5) err(E.INVAL) else err(88); // ENOTSOCK
}

fn socketpair(domain: u64, kind: u64, protocol: u64, out: u64) i64 {
    if (domain != AF_UNIX) return err(97); // EAFNOSUPPORT
    if (protocol != 0) return err(93); // EPROTONOSUPPORT
    const base = kind & SOCK_TYPE_MASK;
    if (base != 1 and base != 2 and base != 5) return err(94); // ESOCKTNOSUPPORT
    if (kind & ~(SOCK_TYPE_MASK | SOCK_NONBLOCK | SOCK_CLOEXEC) != 0) return err(E.INVAL);
    const flags = (if (kind & SOCK_NONBLOCK != 0) FD_NONBLOCK else 0) | (if (kind & SOCK_CLOEXEC != 0) FD_CLOEXEC else 0);
    return raw3(OR.socketpair, base, flags, out);
}

fn messageFlags(flags: u64, allowed: u64) ?u64 {
    if (flags & ~(allowed | MSG_NOSIGNAL) != 0) return null;
    return (if (flags & MSG_DONTWAIT != 0) @as(u64, 1) else 0) |
        (if (flags & MSG_CMSG_CLOEXEC != 0) @as(u64, 2) else 0) |
        (if (flags & MSG_PEEK != 0) @as(u64, 4) else 0) |
        (if (flags & MSG_NOSIGNAL != 0) @as(u64, 8) else 0) |
        (if (flags & MSG_TRUNC_REQUEST != 0) @as(u64, 16) else 0);
}

fn sendMessage(fd: u64, header_address: u64, flags: u64) i64 {
    const native_flags = messageFlags(flags, MSG_DONTWAIT) orelse return err(E.OPNOTSUPP);
    const header: *const MsgHeader = @ptrFromInt(header_address);
    var rights: [MAX_RIGHTS]i32 = undefined;
    var count: usize = 0;
    var offset: u64 = 0;
    while (offset + CMSG_HEADER <= header.controllen) {
        const at = header.control + offset;
        const length = @as(*const u64, @ptrFromInt(at)).*;
        const level = @as(*const i32, @ptrFromInt(at + 8)).*;
        const kind = @as(*const i32, @ptrFromInt(at + 12)).*;
        if (length < CMSG_HEADER or offset + length > header.controllen) return err(E.INVAL);
        if (level != SOL_SOCKET or kind != SCM_RIGHTS) return err(E.INVAL);
        const n: usize = @intCast((length - CMSG_HEADER) / 4);
        if (count + n > MAX_RIGHTS) return err(E.INVAL);
        const data: [*]const i32 = @ptrFromInt(at + CMSG_HEADER);
        @memcpy(rights[count .. count + n], data[0..n]);
        count += n;
        offset += std.mem.alignForward(u64, length, 8);
    }
    var message = NativeMessage{ .iov = header.iov, .iov_count = header.iovlen, .fds = @intFromPtr(&rights), .fd_count = @intCast(count), .flags = 0, .name = header.name, .name_len = header.namelen };
    return raw3(OR.sendmsg, fd, @intFromPtr(&message), native_flags);
}

fn receiveMessage(fd: u64, header_address: u64, flags: u64) i64 {
    const native_flags = messageFlags(flags, MSG_DONTWAIT | MSG_CMSG_CLOEXEC | MSG_PEEK | MSG_TRUNC_REQUEST) orelse return err(E.OPNOTSUPP);
    const header: *MsgHeader = @ptrFromInt(header_address);
    // Room for descriptors in the caller's control buffer.
    const room: usize = if (header.control != 0 and header.controllen > CMSG_HEADER)
        @intCast(@min((header.controllen - CMSG_HEADER) / 4, MAX_RIGHTS))
    else
        0;
    var rights: [MAX_RIGHTS]i32 = undefined;
    var message = NativeMessage{ .iov = header.iov, .iov_count = header.iovlen, .fds = @intFromPtr(&rights), .fd_count = @intCast(room), .flags = 0, .name = header.name, .name_len = header.namelen };
    const r = raw3(OR.recvmsg, fd, @intFromPtr(&message), native_flags);
    if (r < 0) return r;
    if (header.name != 0) header.namelen = message.name_len;
    header.flags = 0;
    if (message.flags & 1 != 0) header.flags |= MSG_TRUNC;
    if (message.flags & 2 != 0) header.flags |= MSG_CTRUNC;
    if (message.fd_count > 0) {
        const at = header.control;
        const length = CMSG_HEADER + @as(u64, message.fd_count) * 4;
        @as(*u64, @ptrFromInt(at)).* = length;
        @as(*i32, @ptrFromInt(at + 8)).* = SOL_SOCKET;
        @as(*i32, @ptrFromInt(at + 12)).* = SCM_RIGHTS;
        const data: [*]i32 = @ptrFromInt(at + CMSG_HEADER);
        @memcpy(data[0..message.fd_count], rights[0..message.fd_count]);
        header.controllen = std.mem.alignForward(u64, length, 8);
    } else header.controllen = 0;
    return r;
}

// ── Waiting for children ────────────────────────────────────────────────────

const WNOHANG: u64 = 1;

/// wait4 for one child: its exit code in a normal-exit status word. Waiting
/// for any child (pid <= 0) is not offered.
fn wait4(pid: i64, status: u64, options: u64, usage: u64) i64 {
    if (pid <= 0) return err(E.NOSYS);
    if (options & ~WNOHANG != 0) return err(E.INVAL);
    const r = raw2(OR.wait, @intCast(pid), if (options & WNOHANG != 0) 1 else 0);
    if (r == err(E.AGAIN)) return 0; // WNOHANG and still running
    if (r < 0 and r > -4096) return r;
    if (status != 0) @as(*c_int, @ptrFromInt(status)).* = (@as(c_int, @truncate(r)) & 0xff) << 8;
    if (usage != 0) @memset(@as([*]u8, @ptrFromInt(usage))[0..144], 0); // struct rusage
    return pid;
}

// ── posix_spawn ─────────────────────────────────────────────────────────────
// There is no fork or exec. A spawn request carries everything the new
// program starts with: path, arguments, environment, working directory and
// an exact descriptor list. posix_spawn works that list out here from the
// caller's descriptors and the file actions, as the child would see its
// table just before exec.

extern fn malloc(size: usize) ?[*]u8;
extern fn free(pointer: ?*anyopaque) void;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const FDOP_CLOSE = 1;
const FDOP_DUP2 = 2;
const FDOP_OPEN = 3;
const FDOP_CHDIR = 4;
const FDOP_FCHDIR = 5;

/// musl's struct fdop; `path` (a flexible array) starts at byte 36.
const FdOp = extern struct { next: ?*FdOp, prev: ?*FdOp, cmd: c_int, fd: c_int, srcfd: c_int, oflag: c_int, mode: u32 };
const FileActions = extern struct { pad0: [2]c_int, actions: ?*FdOp, pad: [16]c_int };

const POSIX_SPAWN_RESETIDS = 1;
const POSIX_SPAWN_SETSIGDEF = 4;
const POSIX_SPAWN_SETSIGMASK = 8;
const POSIX_SPAWN_USEVFORK = 64;
/// Signal settings mean nothing without signals, and ids are all 0.
const SPAWN_FLAGS_HONOURED = POSIX_SPAWN_RESETIDS | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_USEVFORK;

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

const MAX_DESCRIPTORS = 256;
const ARG_MAX = 32 * 1024;
const Slot = struct { parent: i32 = -1, cloexec: bool = false };
const StringList = [*]const ?[*:0]const u8;

fn pack(list: ?StringList, out: []u8, used: *usize) bool {
    const strings = list orelse return true;
    var i: usize = 0;
    while (strings[i]) |string| : (i += 1) {
        const text = std.mem.span(string);
        if (used.* + text.len + 1 > out.len) return false;
        @memcpy(out[used.* .. used.* + text.len], text);
        out[used.* + text.len] = 0;
        used.* += text.len + 1;
    }
    return true;
}

/// `path` relative to `base` (or absolute), as a canonical absolute path in
/// `out`. Returns its length or a negative errno.
fn join(base: []const u8, path: []const u8, out: *[256]u8) i64 {
    var joined: [520]u8 = undefined;
    const full = if (path.len > 0 and path[0] == '/') path else blk: {
        if (base.len + 1 + path.len > joined.len) return err(E.NAMETOOLONG);
        @memcpy(joined[0..base.len], base);
        joined[base.len] = '/';
        @memcpy(joined[base.len + 1 .. base.len + 1 + path.len], path);
        break :blk joined[0 .. base.len + 1 + path.len];
    };
    return raw(OR.resolve_path, std.math.maxInt(u64), @intFromPtr(full.ptr), full.len, @intFromPtr(out), out.len);
}

export fn posix_spawn(
    pid_out: ?*c_int,
    path: [*:0]const u8,
    file_actions: ?*const FileActions,
    attributes: ?*const c_int,
    argv: ?StringList,
    envp: ?StringList,
) callconv(.c) c_int {
    if (attributes) |flags| if (flags.* & ~@as(c_int, SPAWN_FLAGS_HONOURED) != 0) return E.OPNOTSUPP;

    // The descriptor table the child would have before exec.
    var slots: [MAX_DESCRIPTORS]Slot = [_]Slot{.{}} ** MAX_DESCRIPTORS;
    for (&slots, 0..) |*slot, fd| {
        const flags = raw3(OR.fd_control, fd, 2, 0); // GETFD
        if (flags >= 0) slot.* = .{ .parent = @intCast(fd), .cloexec = flags & 1 != 0 };
    }
    var temporaries: [MAX_DESCRIPTORS]i32 = undefined;
    var temporary_count: usize = 0;
    defer for (temporaries[0..temporary_count]) |fd| {
        _ = raw1(OR.close, @intCast(fd));
    };
    var cwd_buffer: [256]u8 = undefined;
    var cwd: ?[]const u8 = null;

    if (file_actions) |fa| if (fa.actions) |first| {
        var op: ?*FdOp = first;
        while (op.?.next) |next| op = next;
        while (op) |action| : (op = action.prev) {
            // Chdir actions carry no descriptor (musl stores -1).
            const uses_fd = action.cmd == FDOP_CLOSE or action.cmd == FDOP_DUP2 or action.cmd == FDOP_OPEN or action.cmd == FDOP_FCHDIR;
            if (uses_fd and (action.fd < 0 or action.fd >= MAX_DESCRIPTORS)) return E.BADF;
            const fd: usize = if (uses_fd) @intCast(action.fd) else 0;
            const action_path = std.mem.span(@as([*:0]const u8, @ptrFromInt(@intFromPtr(action) + 36)));
            switch (action.cmd) {
                FDOP_CLOSE => slots[fd] = .{},
                FDOP_DUP2 => {
                    const source: usize = @intCast(action.srcfd);
                    if (source >= MAX_DESCRIPTORS or slots[source].parent < 0) return E.BADF;
                    slots[fd] = .{ .parent = slots[source].parent, .cloexec = false };
                },
                FDOP_OPEN => {
                    var here: [256]u8 = undefined;
                    const base = cwd orelse blk: {
                        const len = raw2(OR.getcwd, @intFromPtr(&here), here.len);
                        if (len < 0) return @intCast(-len);
                        break :blk here[0..@intCast(len - 1)];
                    };
                    var full: [257]u8 = undefined;
                    const len = join(base, action_path, full[0..256]);
                    if (len < 0) return @intCast(-len);
                    full[@intCast(len)] = 0;
                    const opened = openPath(AT_FDCWD, @intFromPtr(&full), @as(u64, @bitCast(@as(i64, action.oflag))) | O_CLOEXEC);
                    if (opened < 0) return @intCast(-opened);
                    temporaries[temporary_count] = @intCast(opened);
                    temporary_count += 1;
                    slots[fd] = .{ .parent = @intCast(opened), .cloexec = false };
                },
                FDOP_CHDIR => {
                    var here: [256]u8 = undefined;
                    const base = cwd orelse blk: {
                        const len = raw2(OR.getcwd, @intFromPtr(&here), here.len);
                        if (len < 0) return @intCast(-len);
                        break :blk here[0..@intCast(len - 1)];
                    };
                    const len = join(base, action_path, &cwd_buffer);
                    if (len < 0) return @intCast(-len);
                    cwd = cwd_buffer[0..@intCast(len)];
                },
                FDOP_FCHDIR => {
                    if (slots[fd].parent < 0) return E.BADF;
                    const len = raw(OR.resolve_path, @intCast(slots[fd].parent), @intFromPtr("."), 1, @intFromPtr(&cwd_buffer), cwd_buffer.len);
                    if (len < 0) return @intCast(-len);
                    cwd = cwd_buffer[0..@intCast(len)];
                },
                else => return E.INVAL,
            }
        }
    };

    var pairs: [MAX_DESCRIPTORS][2]i32 = undefined;
    var pair_count: usize = 0;
    for (slots, 0..) |slot, fd| {
        if (slot.parent < 0 or slot.cloexec) continue;
        pairs[pair_count] = .{ @intCast(fd), slot.parent };
        pair_count += 1;
    }

    const strings = malloc(ARG_MAX) orelse return E.NOMEM;
    defer free(strings);
    var args_len: usize = 0;
    if (!pack(argv, strings[0..ARG_MAX], &args_len)) return 7; // E2BIG
    var env_len: usize = 0;
    if (!pack(envp, strings[args_len..ARG_MAX], &env_len)) return 7;

    const program = std.mem.span(path);
    var request = SpawnRequest{
        .path = @intFromPtr(program.ptr),
        .path_len = program.len,
        .args = @intFromPtr(strings),
        .args_len = args_len,
        .env = @intFromPtr(strings + args_len),
        .env_len = env_len,
        .fds = @intFromPtr(&pairs),
        .fd_count = pair_count,
        .cwd = if (cwd) |dir| @intFromPtr(dir.ptr) else 0,
        .cwd_len = if (cwd) |dir| dir.len else 0,
    };
    const pid = raw1(OR.spawn_process, @intFromPtr(&request));
    if (pid < 0) return @intCast(-pid);
    if (pid_out) |out| out.* = @intCast(pid);
    return 0;
}

/// posix_spawn with a PATH search when `file` has no slash.
export fn posix_spawnp(
    pid_out: ?*c_int,
    file: [*:0]const u8,
    file_actions: ?*const FileActions,
    attributes: ?*const c_int,
    argv: ?StringList,
    envp: ?StringList,
) callconv(.c) c_int {
    const name = std.mem.span(file);
    if (name.len == 0) return E.NOENT;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return posix_spawn(pid_out, file, file_actions, attributes, argv, envp);
    const search = if (getenv("PATH")) |value| std.mem.span(value) else "/usr/local/bin:/bin:/usr/bin";
    var last: c_int = E.NOENT;
    var it = std.mem.splitScalar(u8, search, ':');
    while (it.next()) |dir| {
        var candidate: [257]u8 = undefined;
        const base = if (dir.len == 0) "." else dir;
        if (base.len + 1 + name.len > 256) continue;
        @memcpy(candidate[0..base.len], base);
        candidate[base.len] = '/';
        @memcpy(candidate[base.len + 1 .. base.len + 1 + name.len], name);
        candidate[base.len + 1 + name.len] = 0;
        var status: Status = undefined;
        if (raw3(OR.stat, @intFromPtr(&candidate), base.len + 1 + name.len, @intFromPtr(&status)) < 0) continue;
        last = posix_spawn(pid_out, @ptrCast(&candidate), file_actions, attributes, argv, envp);
        if (last != E.NOENT and last != E.ACCES) return last;
    }
    return last;
}

// ── Readiness ───────────────────────────────────────────────────────────────

/// A `struct timespec *` timeout in milliseconds, rounded up; null pointer
/// means wait indefinitely (-1). Invalid values give null.
fn timeoutMs(address: u64) ?u64 {
    if (address == 0) return @bitCast(@as(i64, -1));
    const ts: *const Timespec = @ptrFromInt(address);
    if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) return null;
    const ms = @as(u64, @intCast(ts.sec)) * 1000 + (@as(u64, @intCast(ts.nsec)) + 999_999) / 1_000_000;
    return @min(ms, std.math.maxInt(i32));
}

/// A `struct timeval *` timeout, as timeoutMs.
fn timevalMs(address: u64) ?u64 {
    const tv: *const [2]i64 = @ptrFromInt(address);
    if (tv[0] < 0 or tv[1] < 0 or tv[1] >= 1_000_000) return null;
    const ms = @as(u64, @intCast(tv[0])) * 1000 + (@as(u64, @intCast(tv[1])) + 999) / 1000;
    return @min(ms, std.math.maxInt(i32));
}

const PollFd = extern struct { fd: i32, events: i16, revents: i16 };
const POLLIN: i16 = 0x001;
const POLLPRI: i16 = 0x002;
const POLLOUT: i16 = 0x004;
const POLLERR: i16 = 0x008;
const POLLHUP: i16 = 0x010;
const POLLNVAL: i16 = 0x020;
const FD_SETSIZE = 1024;

fn inSet(set: u64, fd: usize) bool {
    if (set == 0) return false;
    const words: [*]const u64 = @ptrFromInt(set);
    return words[fd / 64] & (@as(u64, 1) << @intCast(fd % 64)) != 0;
}

fn addToSet(set: u64, fd: usize) void {
    const words: [*]u64 = @ptrFromInt(set);
    words[fd / 64] |= @as(u64, 1) << @intCast(fd % 64);
}

/// select/pselect on top of poll. `timeout` null: invalid; the sentinel
/// maxInt(u64) (from a null pointer): indefinite.
fn select(nfds: u64, readers: u64, writers: u64, exceptions: u64, timeout: ??u64) i64 {
    if (nfds > FD_SETSIZE) return err(E.INVAL);
    const ms: u64 = if (timeout) |t| (t orelse return err(E.INVAL)) else @bitCast(@as(i64, -1));
    var fds: [FD_SETSIZE]PollFd = undefined;
    var count: usize = 0;
    for (0..@intCast(nfds)) |fd| {
        var events: i16 = 0;
        if (inSet(readers, fd)) events |= POLLIN;
        if (inSet(writers, fd)) events |= POLLOUT;
        if (inSet(exceptions, fd)) events |= POLLPRI;
        if (events == 0) continue;
        fds[count] = .{ .fd = @intCast(fd), .events = events, .revents = 0 };
        count += 1;
    }
    const r = raw3(OR.poll, @intFromPtr(&fds), count, ms);
    if (r < 0) return r;
    const words = (nfds + 63) / 64;
    for ([_]u64{ readers, writers, exceptions }) |set| {
        if (set != 0) @memset(@as([*]u64, @ptrFromInt(set))[0..@intCast(words)], 0);
    }
    var ready: i64 = 0;
    for (fds[0..count]) |entry| {
        if (entry.revents & POLLNVAL != 0) return err(E.BADF);
        const fd: usize = @intCast(entry.fd);
        if (entry.events & POLLIN != 0 and entry.revents & (POLLIN | POLLHUP | POLLERR) != 0) {
            addToSet(readers, fd);
            ready += 1;
        }
        if (entry.events & POLLOUT != 0 and entry.revents & (POLLOUT | POLLERR) != 0) {
            addToSet(writers, fd);
            ready += 1;
        }
        if (entry.events & POLLPRI != 0 and entry.revents & POLLPRI != 0) {
            addToSet(exceptions, fd);
            ready += 1;
        }
    }
    return ready;
}

// ── Futexes ─────────────────────────────────────────────────────────────────

const FUTEX_WAIT = 0;
const FUTEX_WAKE = 1;
const FUTEX_REQUEUE = 3;
const FUTEX_CMP_REQUEUE = 4;
const FUTEX_WAIT_BITSET = 9;
const FUTEX_WAKE_BITSET = 10;
const FUTEX_CLOCK_REALTIME = 256;
/// The kernel caps one wait at a minute; longer waits come back early.
const WAIT_CAP_MS: u64 = 60_000;

fn futexWait(address: u64, expected: u64, relative_ns: ?u64) i64 {
    var ms: u64 = 0;
    var capped = false;
    if (relative_ns) |ns| {
        if (ns == 0) return err(E.TIMEDOUT);
        ms = @max((ns + 999_999) / 1_000_000, 1);
        if (ms > WAIT_CAP_MS) {
            ms = WAIT_CAP_MS;
            capped = true;
        }
    }
    const r = raw3(OR.user_wait, address, expected & 0xffff_ffff, ms);
    // A capped wait that expires is reported as a spurious wake: the caller
    // rechecks its condition and waits again with its own deadline.
    if (r == -110) return if (capped) 0 else err(E.TIMEDOUT);
    return r;
}

fn futexWake(address: u64, count: u64) i64 {
    var remaining = @min(count, std.math.maxInt(i32));
    var woken: i64 = 0;
    while (remaining > 0) {
        const batch = @min(remaining, 64);
        const r = raw2(OR.user_wake, address, batch);
        if (r < 0) return if (woken > 0) woken else r;
        woken += r;
        if (@as(u64, @intCast(r)) < batch) break;
        remaining -= batch;
    }
    return woken;
}

fn futex(address: u64, op: u64, value: u64, timeout: u64, address2: u64, value3: u64) i64 {
    _ = address2;
    const command = op & 0x7f;
    switch (command) {
        FUTEX_WAIT => {
            const relative: ?u64 = if (timeout == 0) null else blk: {
                const ts: *const Timespec = @ptrFromInt(timeout);
                if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) return err(E.INVAL);
                break :blk @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
            };
            return futexWait(address, value, relative);
        },
        FUTEX_WAIT_BITSET => {
            // Absolute deadline on the monotonic or realtime clock.
            const relative: ?u64 = if (timeout == 0) null else blk: {
                const ts: *const Timespec = @ptrFromInt(timeout);
                if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) return err(E.INVAL);
                const deadline = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
                const now = clockNs(if (op & FUTEX_CLOCK_REALTIME != 0) 1 else 0) orelse return err(E.INVAL);
                if (deadline <= now) return err(E.TIMEDOUT);
                break :blk deadline - now;
            };
            return futexWait(address, value, relative);
        },
        FUTEX_WAKE, FUTEX_WAKE_BITSET => return futexWake(address, value),
        // Requeueing waiters onto another word is replaced by waking them:
        // futex waits may wake spuriously, and each rechecks its condition.
        FUTEX_REQUEUE => return futexWake(address, value +| timeout),
        FUTEX_CMP_REQUEUE => {
            const word: *const volatile u32 = @ptrFromInt(address);
            if (word.* != @as(u32, @truncate(value3))) return err(E.AGAIN);
            return futexWake(address, value +| timeout);
        },
        else => return err(E.NOSYS),
    }
}

// ── The translation table ───────────────────────────────────────────────────

/// ORANGE_SYSCALL_TRACE=1 in a program's environment logs every Linux call
/// it makes, with its first four arguments and the result, to its standard
/// error: a porting aid, and nothing when unset. Decided at the first call
/// made once musl has set up the environment.
const Trace = enum(u8) { unknown, off, on };
var trace: Trace = .unknown;
extern var __environ: ?[*]?[*:0]const u8;

fn tracing() bool {
    if (trace == .unknown) {
        const environment = __environ orelse return false;
        trace = .off;
        var i: usize = 0;
        while (environment[i]) |entry| : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(entry), "ORANGE_SYSCALL_TRACE=1")) trace = .on;
        }
    }
    return trace == .on;
}

export fn __orange_syscall(n: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64, a6: i64) callconv(.c) i64 {
    const r = translate(n, a1, a2, a3, a4, a5, a6);
    if (tracing()) {
        var line: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&line, "[trace] {d}({x}, {x}, {x}, {x}) = {d}\n", .{
            n, @as(u64, @bitCast(a1)), @as(u64, @bitCast(a2)), @as(u64, @bitCast(a3)), @as(u64, @bitCast(a4)), r,
        }) catch line[0..0];
        _ = raw3(OR.write, 2, @intFromPtr(text.ptr), text.len);
    }
    return r;
}

fn translate(n: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64, a6: i64) i64 {
    const a: u64 = @bitCast(a1);
    const b: u64 = @bitCast(a2);
    const c: u64 = @bitCast(a3);
    const d: u64 = @bitCast(a4);
    const e: u64 = @bitCast(a5);
    const f: u64 = @bitCast(a6);
    return dispatch: switch (n) {
        SYS.read => raw3(OR.read, a, b, @min(c, 4096)),
        SYS.write => raw3(OR.write, a, b, @min(c, 4096)),
        SYS.pread64 => raw(OR.pread, a, b, @min(c, 4096), d, 0),
        SYS.pwrite64 => raw(OR.pwrite, a, b, @min(c, 4096), d, 0),
        SYS.readv => vectored(OR.read, a, b, c),
        SYS.writev => vectored(OR.write, a, b, c),
        SYS.open => openPath(AT_FDCWD, a, b),
        SYS.openat => openPath(a1, b, c),
        SYS.close => raw1(OR.close, a),
        SYS.lseek => raw3(OR.seek, a, b, c),
        SYS.stat, SYS.lstat => blk: {
            var status: Status = undefined;
            const r = statusOf(AT_FDCWD, a, 0, &status);
            if (r < 0) break :blk r;
            fillKStat(b, status);
            break :blk 0;
        },
        SYS.fstat => blk: {
            var status: Status = undefined;
            const r = raw2(OR.fstat, a, @intFromPtr(&status));
            if (r < 0) break :blk r;
            fillKStat(b, status);
            break :blk 0;
        },
        SYS.newfstatat => blk: {
            var status: Status = undefined;
            const r = statusOf(a1, b, d, &status);
            if (r < 0) break :blk r;
            fillKStat(c, status);
            break :blk 0;
        },
        SYS.statx => blk: {
            var status: Status = undefined;
            const r = statusOf(a1, b, c, &status);
            if (r < 0) break :blk r;
            const out: *Statx = @ptrFromInt(e);
            out.* = .{
                .mask = 0x7ff,
                .blksize = 4096,
                .nlink = 1,
                .mode = @truncate(modeOf(status.kind)),
                .size = status.size,
                .blocks = (status.size + 511) / 512,
            };
            break :blk 0;
        },
        SYS.mkdir => pathCall(OR.mkdir, AT_FDCWD, a),
        SYS.mkdirat => pathCall(OR.mkdir, a1, b),
        SYS.rmdir => pathCall(OR.rmdir, AT_FDCWD, a),
        SYS.unlink => pathCall(OR.unlink, AT_FDCWD, a),
        SYS.unlinkat => if (c & ~AT_REMOVEDIR != 0) err(E.INVAL) else pathCall(if (c & AT_REMOVEDIR != 0) OR.rmdir else OR.unlink, a1, b),
        SYS.rename => renamePath(AT_FDCWD, a, AT_FDCWD, b),
        SYS.renameat => renamePath(a1, b, a3, d),
        // RENAME_NOREPLACE and RENAME_EXCHANGE are not offered.
        SYS.renameat2 => if (e != 0) err(E.INVAL) else renamePath(a1, b, a3, d),
        SYS.ftruncate => raw2(OR.ftruncate, a, b),
        SYS.truncate => blk: {
            const fd = openPath(AT_FDCWD, a, O_WRONLY);
            if (fd < 0) break :blk fd;
            const r = raw2(OR.ftruncate, @intCast(fd), b);
            _ = raw1(OR.close, @intCast(fd));
            break :blk r;
        },
        // /data is saved to its disk; /tmp lives in memory and the root is
        // read-only, so for them only the descriptor is checked.
        SYS.fsync, SYS.fdatasync, SYS.syncfs => raw1(OR.fs_sync, a),
        SYS.sync => blk: {
            _ = raw1(OR.fs_sync, std.math.maxInt(u64));
            break :blk 0;
        },
        SYS.getdents64 => getdents(a, b, c),
        SYS.statfs => statfs(a, b),
        SYS.access => accessPath(AT_FDCWD, a, b),
        SYS.faccessat => accessPath(a1, b, c),
        // musl uses faccessat2 whenever flags are given. OrangeOS has no
        // symbolic links and every program's real and effective ids are
        // the same, so AT_SYMLINK_NOFOLLOW (0x100) and AT_EACCESS (0x200)
        // cannot change the answer; other flags are refused.
        SYS.chmod => changeMode(AT_FDCWD, a, 0, b),
        SYS.fchmodat => changeMode(a1, b, 0, c),
        SYS.fchmodat2 => if (d & ~@as(u64, 0x100 | AT_EMPTY_PATH) != 0) err(E.INVAL) else changeMode(a1, b, d, c),
        SYS.fchmod => changeMode(a1, 0, AT_EMPTY_PATH, b),
        SYS.faccessat2 => if (d & ~@as(u64, 0x100 | 0x200) != 0) err(E.INVAL) else accessPath(a1, b, c),
        SYS.mmap => mmap(a, b, c, d, a5, f),
        SYS.mprotect => blk: {
            const prot = translateProt(c) orelse break :blk err(E.ACCES);
            break :blk raw3(OR.mprotect, a, b, prot);
        },
        SYS.munmap => raw2(OR.munmap, a, b),
        // No program break: musl's allocator then uses mmap alone.
        SYS.brk => 0,
        // MREMAP_MAYMOVE (1) is offered; MREMAP_FIXED is not.
        SYS.mremap => if (d & ~@as(u64, 1) != 0) err(E.INVAL) else raw(OR.vm_remap, a, b, c, d, 0),
        // MADV_DONTNEED (4) and MADV_FREE (8) release pages, which read as
        // zeros afterwards; the rest is advice and changes nothing.
        SYS.madvise => if (c == 4 or c == 8) raw3(OR.vm_advise, a, b, 4) else 0,
        // The kernel takes Linux's k_sigaction and 64-bit masks as they are.
        SYS.rt_sigaction => if (d != 8) err(E.INVAL) else raw3(OR.sigaction, a, b, c),
        SYS.rt_sigprocmask => if (d != 8) err(E.INVAL) else raw3(OR.sigmask, a, b, c),
        SYS.rt_sigpending => if (b != 8) err(E.INVAL) else raw1(OR.sigpending, a),
        SYS.sigaltstack => raw2(OR.sigaltstack, a, b),
        SYS.kill => raw2(OR.kill, a, b),
        SYS.tkill => raw2(OR.tkill, a, b),
        SYS.tgkill => if (a != @as(u64, @bitCast(raw0(OR.getpid)))) err(3) else raw2(OR.tkill, b, c), // ESRCH
        SYS.ioctl => ioctl(a, b, c),
        SYS.fcntl => fcntl(a, b, c),
        SYS.pipe => raw2(OR.pipe, a, 0),
        SYS.pipe2 => if (b & ~(O_NONBLOCK | O_CLOEXEC) != 0) err(E.INVAL) else raw2(OR.pipe, a, fdFlags(b)),
        SYS.dup => raw3(OR.dup, a, std.math.maxInt(u64), 0),
        SYS.dup2 => raw3(OR.dup, a, b, 0),
        // dup3 differs from dup2 only in refusing old == new.
        SYS.dup3 => if (a == b or c & ~O_CLOEXEC != 0) err(E.INVAL) else raw3(OR.dup, a, b, fdFlags(c)),
        SYS.poll => raw3(OR.poll, a, b, @bitCast(@as(i64, @as(i32, @truncate(a3))))),
        SYS.ppoll => raw3(OR.poll, a, b, timeoutMs(c) orelse break :dispatch err(E.INVAL)),
        SYS.select => select(a, b, c, d, if (e == 0) null else timevalMs(e)),
        SYS.pselect6 => select(a, b, c, d, if (e == 0) null else timeoutMs(e)),
        // A size argument, ignored as Linux does, but it must be positive.
        SYS.epoll_create => if (a1 <= 0) err(E.INVAL) else raw1(OR.epoll_create, 0),
        SYS.epoll_create1 => if (a & ~O_CLOEXEC != 0) err(E.INVAL) else raw1(OR.epoll_create, fdFlags(a)),
        SYS.epoll_ctl => raw(OR.epoll_ctl, a, b, c, d, 0),
        // No signals are ever delivered, so the pwait masks change nothing.
        SYS.epoll_wait, SYS.epoll_pwait => raw(OR.epoll_wait, a, b, c, @bitCast(@as(i64, @as(i32, @truncate(a4)))), 0),
        SYS.epoll_pwait2 => raw(OR.epoll_wait, a, b, c, timeoutMs(d) orelse break :dispatch err(E.INVAL), 0),
        SYS.socket => socket(a, b, c),
        SYS.socketpair => socketpair(a, b, c, d),
        SYS.sendmsg => sendMessage(a, b, c),
        SYS.recvmsg => receiveMessage(a, b, c),
        SYS.sendto => blk: {
            var vector = Iovec{ .base = b, .len = c };
            var header = MsgHeader{ .iov = @intFromPtr(&vector), .iovlen = 1, .name = e, .namelen = @truncate(f) };
            break :blk sendMessage(a, @intFromPtr(&header), d);
        },
        SYS.recvfrom => blk: {
            var vector = Iovec{ .base = b, .len = c };
            const capacity: u32 = if (e != 0 and f != 0) @as(*const u32, @ptrFromInt(f)).* else 0;
            var header = MsgHeader{ .iov = @intFromPtr(&vector), .iovlen = 1, .name = if (capacity != 0) e else 0, .namelen = capacity };
            const r = receiveMessage(a, @intFromPtr(&header), d);
            if (r >= 0 and e != 0 and f != 0) @as(*u32, @ptrFromInt(f)).* = header.namelen;
            break :blk r;
        },
        SYS.connect => raw3(OR.connect, a, b, c),
        SYS.bind => raw3(OR.bind, a, b, c),
        SYS.listen => raw1(OR.listen, a),
        SYS.accept, SYS.accept4 => accept(a),
        SYS.getsockname => raw(OR.sockname, a, 0, b, c, 0),
        SYS.getpeername => raw(OR.sockname, a, 1, b, c, 0),
        SYS.getsockopt => raw(OR.getsockopt, a, b, c, d, e),
        SYS.setsockopt => raw(OR.setsockopt, a, b, c, d, e),
        SYS.shutdown => raw2(OR.shutdown, a, b),
        SYS.eventfd => raw2(OR.eventfd, a, 0),
        SYS.eventfd2 => blk: {
            const semaphore: u64 = 1; // EFD_SEMAPHORE
            if (b & ~(O_NONBLOCK | O_CLOEXEC | semaphore) != 0) break :blk err(E.INVAL);
            break :blk raw2(OR.eventfd, a, fdFlags(b) | (if (b & semaphore != 0) EFD_SEMAPHORE else 0));
        },
        SYS.sched_yield => raw0(OR.yield),
        SYS.nanosleep => blk: {
            const ts: *const Timespec = @ptrFromInt(a);
            if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) break :blk err(E.INVAL);
            break :blk sleepInterruptible(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec)), b);
        },
        SYS.clock_nanosleep => blk: {
            const ts: *const Timespec = @ptrFromInt(c);
            if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) break :blk err(E.INVAL);
            var ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
            const absolute = b & 1 != 0; // TIMER_ABSTIME
            if (absolute) {
                const now = readClock(a1) orelse break :blk err(E.INVAL);
                ns = ns -| now;
            }
            break :blk sleepInterruptible(ns, if (absolute) 0 else d);
        },
        SYS.clock_gettime => blk: {
            const ns = readClock(a1) orelse break :blk err(E.INVAL);
            const ts: *Timespec = @ptrFromInt(b);
            ts.* = .{ .sec = @intCast(ns / 1_000_000_000), .nsec = @intCast(ns % 1_000_000_000) };
            break :blk 0;
        },
        SYS.clock_getres => blk: {
            if (readClock(a1) == null) break :blk err(E.INVAL);
            if (b != 0) @as(*Timespec, @ptrFromInt(b)).* = .{ .sec = 0, .nsec = 1 };
            break :blk 0;
        },
        SYS.gettimeofday => blk: {
            const ns = clockNs(1) orelse break :blk err(E.INVAL);
            if (a != 0) @as(*[2]i64, @ptrFromInt(a)).* = .{ @intCast(ns / 1_000_000_000), @intCast(ns % 1_000_000_000 / 1000) };
            break :blk 0;
        },
        SYS.time => blk: {
            const ns = clockNs(1) orelse break :blk err(E.INVAL);
            const seconds: i64 = @intCast(ns / 1_000_000_000);
            if (a != 0) @as(*i64, @ptrFromInt(a)).* = seconds;
            break :blk seconds;
        },
        SYS.getpid => raw0(OR.getpid),
        SYS.gettid => raw0(OR.gettid),
        SYS.getppid => raw0(OR.getppid),
        SYS.getuid, SYS.getgid, SYS.geteuid, SYS.getegid => 0,
        SYS.set_tid_address => raw1(OR.set_exit_word, a),
        SYS.arch_prctl => switch (a) {
            0x1002 => raw1(OR.tls_set_base, b), // ARCH_SET_FS
            0x1003 => blk: { // ARCH_GET_FS
                @as(*u64, @ptrFromInt(b)).* = @bitCast(raw0(OR.tls_get_base));
                break :blk 0;
            },
            else => err(E.INVAL),
        },
        SYS.futex => futex(a, b, c, d, e, f),
        SYS.exit => raw1(OR.thread_exit, a),
        SYS.exit_group => raw1(OR.exit, a),
        SYS.uname => uname(a),
        SYS.getcwd => raw2(OR.getcwd, a, b),
        SYS.chdir => pathCall(OR.chdir, AT_FDCWD, a),
        SYS.fchdir => blk: {
            var buffer: [256]u8 = undefined;
            const len = raw(OR.resolve_path, a, @intFromPtr("."), 1, @intFromPtr(&buffer), buffer.len);
            if (len < 0) break :blk len;
            break :blk raw2(OR.chdir, @intFromPtr(&buffer), @intCast(len));
        },
        SYS.wait4 => wait4(a1, b, c, d),
        // GRND_NONBLOCK (1) and GRND_INSECURE (4); GRND_RANDOM (2) changes
        // nothing here, as on current Linux.
        SYS.getrandom => if (c & ~@as(u64, 7) != 0) err(E.INVAL) else raw3(OR.getrandom, a, b, (c & 1) | (if (c & 4 != 0) @as(u64, 2) else 0)),
        SYS.memfd_create => blk: {
            const MFD_CLOEXEC = 1;
            const MFD_ALLOW_SEALING = 2;
            if (b & ~@as(u64, MFD_CLOEXEC | MFD_ALLOW_SEALING) != 0) break :blk err(E.INVAL);
            break :blk raw1(OR.memfd, (if (b & MFD_CLOEXEC != 0) FD_CLOEXEC else 0) | (if (b & MFD_ALLOW_SEALING != 0) @as(u64, 8) else 0));
        },
        SYS.prlimit64 => blk: {
            // Only queries of this process; no limit is enforced beyond the
            // kernel's own tables, which report the descriptor limit.
            if (a != 0 or c != 0) break :blk err(E.PERM);
            if (d != 0) {
                const limit: u64 = if (b == 7) 32 else std.math.maxInt(u64); // RLIMIT_NOFILE
                @as(*[2]u64, @ptrFromInt(d)).* = .{ limit, limit };
            }
            break :blk 0;
        },
        else => err(E.NOSYS),
    };
}

fn openPath(dirfd: i64, path_address: u64, flags: u64) i64 {
    // Anonymous O_TMPFILE files are not offered; callers fall back to a
    // named file they unlink.
    if (flags & O_TMPFILE_ONLY != 0) return err(E.OPNOTSUPP);
    var native: u64 = switch (flags & O_ACCMODE) {
        O_WRONLY => OPEN_WRITE,
        O_RDWR => OPEN_READ | OPEN_WRITE,
        else => OPEN_READ,
    };
    if (flags & O_CREAT != 0) native |= OPEN_CREATE;
    if (flags & O_EXCL != 0) native |= OPEN_EXCLUSIVE;
    if (flags & O_TRUNC != 0) native |= OPEN_TRUNCATE;
    if (flags & O_APPEND != 0) native |= OPEN_APPEND;
    if (flags & O_DIRECTORY != 0) native |= OPEN_DIRECTORY;
    if (flags & O_NONBLOCK != 0) native |= OPEN_NONBLOCK;
    if (flags & O_CLOEXEC != 0) native |= OPEN_CLOEXEC;
    // The mode is ignored: no filesystem has permissions yet.
    var buffer: [256]u8 = undefined;
    return switch (pathAt(dirfd, path_address, &buffer)) {
        .path => |path| raw3(OR.open, @intFromPtr(path.ptr), path.len, native),
        .errno => |code| code,
    };
}

fn accessPath(dirfd: i64, path_address: u64, mode: u64) i64 {
    var status: Status = undefined;
    const r = statusOf(dirfd, path_address, 0, &status);
    if (r < 0) return r;
    // W_OK: only a writable filesystem allows writing.
    if (mode & 2 != 0 and status.mode & OPEN_WRITE == 0) return err(E.ROFS);
    return 0;
}

/// Native directory entry (readdir_fd) and Linux's linux_dirent64.
const NativeDirEntry = extern struct { inode: u32, type: u8, name_len: u8, name: [128]u8 };
const DIRENT_HEADER = 19; // d_ino, d_off, d_reclen, d_type
const DIRENT_MAX = std.mem.alignForward(usize, DIRENT_HEADER + 128 + 1, 8);

fn getdents(fd: u64, out: u64, len: u64) i64 {
    // Ask only for as many entries as are sure to fit: the kernel advances
    // the directory position past every entry it returns.
    const max = @min(len / DIRENT_MAX, 32);
    if (max == 0) return err(E.INVAL);
    var entries: [32]NativeDirEntry = undefined;
    const count = raw3(OR.readdir_fd, fd, @intFromPtr(&entries), max);
    if (count < 0) return count;
    const position = raw3(OR.seek, fd, 0, 1); // SEEK_CUR: the next entry's index
    const bytes: [*]u8 = @ptrFromInt(out);
    var used: usize = 0;
    for (entries[0..@intCast(count)], 0..) |entry, i| {
        const record = std.mem.alignForward(usize, DIRENT_HEADER + entry.name_len + 1, 8);
        const at = bytes + used;
        std.mem.writeInt(u64, at[0..8], entry.inode, .little);
        const next: i64 = if (position < 0) @intCast(i + 1) else position - count + @as(i64, @intCast(i)) + 1;
        std.mem.writeInt(i64, at[8..16], next, .little);
        std.mem.writeInt(u16, at[16..18], @intCast(record), .little);
        at[18] = switch (entry.type) { // DT_DIR, DT_REG, DT_CHR, DT_UNKNOWN
            2 => 4,
            1 => 8,
            3 => 2,
            else => 0,
        };
        @memcpy(at[DIRENT_HEADER .. DIRENT_HEADER + entry.name_len], entry.name[0..entry.name_len]);
        @memset(at[DIRENT_HEADER + entry.name_len .. record], 0);
        used += record;
    }
    return @intCast(used);
}

/// Linux `struct statfs` for x86-64.
const LinuxStatfs = extern struct {
    type: u64,
    bsize: u64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64 = 0,
    ffree: u64 = 0,
    fsid: [2]i32 = .{ 0, 0 },
    namelen: u64 = 128,
    frsize: u64,
    flags: u64,
    spare: [4]u64 = [_]u64{0} ** 4,
};
const FsStatus = extern struct { total_bytes: u64, free_bytes: u64, read_only: u32, reserved: u32 };

fn statfs(path_address: u64, out: u64) i64 {
    var buffer: [256]u8 = undefined;
    const path = switch (pathAt(AT_FDCWD, path_address, &buffer)) {
        .path => |p| p,
        .errno => |code| return code,
    };
    var status: FsStatus = undefined;
    const r = raw3(OR.statfs, @intFromPtr(path.ptr), path.len, @intFromPtr(&status));
    if (r < 0) return r;
    const result: *LinuxStatfs = @ptrFromInt(out);
    result.* = .{
        // TMPFS_MAGIC for a writable (in-memory) filesystem; the root
        // filesystem has no Linux magic number of its own.
        .type = if (status.read_only != 0) 0x4f524e47 else 0x01021994,
        .bsize = 4096,
        .blocks = status.total_bytes / 4096,
        .bfree = status.free_bytes / 4096,
        .bavail = status.free_bytes / 4096,
        .frsize = 4096,
        .flags = if (status.read_only != 0) 1 else 0, // ST_RDONLY
    };
    return 0;
}

/// Linux PROT_* to OrangeOS protection: write implies read (x86 has no
/// write-only pages); writable and executable together is refused (W^X).
fn translateProt(prot: u64) ?u64 {
    return switch (prot & 7) {
        0 => 0,
        1 => 1,
        2, 3 => 3,
        4, 5 => 5,
        else => null,
    };
}

const MAP_PRIVATE: u64 = 0x02;
const MAP_FIXED: u64 = 0x10;
const MAP_ANONYMOUS: u64 = 0x20;
const MAP_NORESERVE: u64 = 0x4000;
const MAP_STACK: u64 = 0x20000;

const MAP_POPULATE: u64 = 0x8000;
const MAP_FIXED_NOREPLACE: u64 = 0x100000;
/// Native vm_map flags.
const VM_FIXED: u64 = 1;
const VM_FIXED_NOREPLACE: u64 = 2;
const VM_HINT: u64 = 4;
const VM_SHARED: u64 = 8;
const MAP_SHARED: u64 = 0x01;
/// MAP_SHARED_VALIDATE: shared, with unknown flags refused (which they are).
const MAP_SHARED_VALIDATE: u64 = 0x03;

fn mmap(address: u64, length: u64, prot: u64, flags: u64, fd: i64, offset: u64) i64 {
    // MAP_POPULATE only prefetches, and pages appear on first touch anyway.
    const ignored = MAP_NORESERVE | MAP_STACK | MAP_POPULATE | MAP_FIXED | MAP_FIXED_NOREPLACE | MAP_ANONYMOUS;
    const sharing = flags & ~ignored;
    if (sharing != MAP_PRIVATE and sharing != MAP_SHARED and sharing != MAP_SHARED_VALIDATE) return err(E.INVAL);
    const native = translateProt(prot) orelse return err(E.ACCES);
    var placement: u64 = if (flags & MAP_FIXED_NOREPLACE != 0)
        VM_FIXED_NOREPLACE
    else if (flags & MAP_FIXED != 0)
        VM_FIXED
    else if (address != 0)
        VM_HINT
    else
        0;
    if (flags & MAP_ANONYMOUS != 0) {
        // Shared anonymous memory is only shared with fork()ed children, and
        // there is no fork: it is private memory.
        if (offset != 0) return err(E.INVAL);
        return raw6(OR.vm_map, address, length, native, placement, std.math.maxInt(u64), 0);
    }
    if (sharing != MAP_PRIVATE) placement |= VM_SHARED;
    return raw6(OR.vm_map, address, length, native, placement, @bitCast(fd), offset);
}

fn ioctl(fd: u64, request: u64, argument: u64) i64 {
    switch (request) {
        // TIOCGWINSZ: the console and terminals answer, so stdio line-buffers
        // them; nothing else is a terminal.
        0x5413 => {
            var status: Status = undefined;
            const r = raw2(OR.fstat, fd, @intFromPtr(&status));
            if (r < 0) return r;
            if (status.kind != 3) return err(E.NOTTY);
            const size: *[4]u16 = @ptrFromInt(argument);
            size.* = .{ 25, 80, 0, 0 };
            return 0;
        },
        // FIONREAD: bytes waiting (sockets, pipes), which fstat reports.
        0x541B => {
            var status: Status = undefined;
            const r = raw2(OR.fstat, fd, @intFromPtr(&status));
            if (r < 0) return r;
            if (status.kind != 4 and status.kind != 5) return err(E.NOTTY);
            @as(*c_int, @ptrFromInt(argument)).* = @intCast(@min(status.size, std.math.maxInt(c_int)));
            return 0;
        },
        // FIONBIO: set or clear nonblocking mode.
        0x5421 => {
            const on = @as(*const c_int, @ptrFromInt(argument)).* != 0;
            const flags = raw3(OR.fd_control, fd, 4, 0);
            if (flags < 0) return flags;
            const status: u64 = @intCast(flags);
            return raw3(OR.fd_control, fd, 5, if (on) status | OPEN_NONBLOCK else status & ~OPEN_NONBLOCK);
        },
        else => return err(E.NOTTY),
    }
}

const F_DUPFD = 0;
const F_GETFD = 1;
const F_SETFD = 2;
const F_GETFL = 3;
const F_SETFL = 4;
const F_DUPFD_CLOEXEC = 1030;
const F_ADD_SEALS = 1033;
const F_GET_SEALS = 1034;
const F_GETLK = 5;
const F_SETLK = 6;
const F_SETLKW = 7;
const F_OFD_GETLK = 36;
const F_OFD_SETLK = 37;
const F_OFD_SETLKW = 38;
const FD_CLOEXEC_BIT = 1;

fn fcntl(fd: u64, command: u64, argument: u64) i64 {
    return switch (command) {
        F_DUPFD => raw3(OR.fd_control, fd, 0, argument),
        F_DUPFD_CLOEXEC => raw3(OR.fd_control, fd, 1, argument),
        F_GETFD => raw3(OR.fd_control, fd, 2, 0),
        F_SETFD => raw3(OR.fd_control, fd, 3, argument & FD_CLOEXEC_BIT),
        F_GETFL => blk: {
            const flags = raw3(OR.fd_control, fd, 4, 0);
            if (flags < 0) break :blk flags;
            const status: u64 = @intCast(flags);
            const read = status & OPEN_READ != 0;
            const write = status & OPEN_WRITE != 0;
            var linux: u64 = if (read and write) O_RDWR else if (write) O_WRONLY else 0;
            if (status & OPEN_APPEND != 0) linux |= O_APPEND;
            if (status & OPEN_NONBLOCK != 0) linux |= O_NONBLOCK;
            break :blk @intCast(linux);
        },
        F_ADD_SEALS => raw3(OR.fd_control, fd, 6, argument),
        F_GET_SEALS => raw3(OR.fd_control, fd, 7, 0),
        // Record locks. The native request has struct flock's layout, so
        // the caller's structure is passed as it is.
        F_GETLK => raw3(OR.fd_control, fd, 8, argument),
        F_SETLK => raw3(OR.fd_control, fd, 9, argument),
        F_SETLKW => raw3(OR.fd_control, fd, 10, argument),
        F_OFD_GETLK => raw3(OR.fd_control, fd, 11, argument),
        F_OFD_SETLK => raw3(OR.fd_control, fd, 12, argument),
        F_OFD_SETLKW => raw3(OR.fd_control, fd, 13, argument),
        F_SETFL => raw3(OR.fd_control, fd, 5, (if (argument & O_APPEND != 0) OPEN_APPEND else 0) |
            (if (argument & O_NONBLOCK != 0) OPEN_NONBLOCK else 0)),
        else => err(E.INVAL),
    };
}

fn uname(address: u64) i64 {
    const fields: *[6][65]u8 = @ptrFromInt(address);
    const values = [_][]const u8{ "OrangeOS", "orange", "0.1.0", "Zest", "x86_64", "" };
    for (fields, values) |*field, value| {
        @memset(field, 0);
        @memcpy(field[0..value.len], value);
    }
    return 0;
}

// ── Replacements for musl's raw-syscall assembly ────────────────────────────

export fn __set_thread_area(pointer: usize) callconv(.c) c_int {
    return @intCast(raw1(OR.tls_set_base, pointer));
}

const CLONE_SETTLS = 0x80000;
const CLONE_PARENT_SETTID = 0x100000;
const CLONE_CHILD_CLEARTID = 0x200000;

/// Where a new thread starts, stored at the top of its own stack.
const CloneStart = extern struct {
    function: *const fn (?*anyopaque) callconv(.c) c_int,
    argument: ?*anyopaque,
    tid_out: ?*c_int,
};

fn cloneEntry(start_address: usize) callconv(.c) noreturn {
    const start: *const CloneStart = @ptrFromInt(start_address);
    // CLONE_PARENT_SETTID: the thread may need its tid before the creator
    // returns, so it stores its own too.
    if (start.tid_out) |out| @atomicStore(c_int, out, @intCast(raw0(OR.gettid)), .release);
    const code = start.function(start.argument);
    _ = raw1(OR.thread_exit, @as(u64, @bitCast(@as(i64, code))));
    unreachable;
}

/// musl's thread-creation primitive. Honors the flags musl uses: the thread
/// shares the address space, descriptors and handles (always true for an
/// OrangeOS thread), takes `tls` as its thread pointer, has its tid stored at
/// `ptid`, and has `ctid` cleared and woken when it exits.
export fn __clone(
    function: *const fn (?*anyopaque) callconv(.c) c_int,
    stack: usize,
    flags: c_int,
    argument: ?*anyopaque,
    ptid: ?*c_int,
    tls: usize,
    ctid: ?*c_int,
) callconv(.c) c_int {
    const bits: u32 = @bitCast(flags);
    const top = std.mem.alignBackward(usize, stack, 16) - std.mem.alignForward(usize, @sizeOf(CloneStart), 16);
    const start: *CloneStart = @ptrFromInt(top);
    start.* = .{
        .function = function,
        .argument = argument,
        .tid_out = if (bits & CLONE_PARENT_SETTID != 0) ptid else null,
    };
    // A zero return slot: the entry sees rsp = 8 mod 16, as after a CALL.
    const rsp = top - 8;
    @as(*usize, @ptrFromInt(rsp)).* = 0;
    const tid = raw(
        OR.thread_create,
        @intFromPtr(&cloneEntry),
        rsp,
        top,
        if (bits & CLONE_SETTLS != 0) tls else 0,
        if (bits & CLONE_CHILD_CLEARTID != 0) @intFromPtr(ctid) else 0,
    );
    if (tid < 0) return @intCast(tid);
    if (bits & CLONE_PARENT_SETTID != 0) {
        if (ptid) |out| @atomicStore(c_int, out, @intCast(tid), .release);
    }
    return @intCast(tid);
}

// Cancellable system calls: the labels let musl's cancellation code tell
// whether a thread is inside the call. The system call itself is made in
// __orange_syscall, outside the labels, so a cancellation request acts at the
// check before a call rather than interrupting one. __unmapself removes the
// calling thread's own stack and exits without touching it in between.
//
// __restore_rt and __restore are the signal restorers: a handler returns into
// one with the stack at the saved ucontext, which OrangeOS's sigreturn (154)
// restores.
comptime {
    asm (
        \\.text
        \\.global __syscall_cp_asm
        \\.hidden __syscall_cp_asm
        \\.global __cp_begin
        \\.hidden __cp_begin
        \\.global __cp_end
        \\.hidden __cp_end
        \\.global __cp_cancel
        \\.hidden __cp_cancel
        \\.type __syscall_cp_asm,@function
        \\__syscall_cp_asm:
        \\__cp_begin:
        \\    mov (%rdi),%eax
        \\    test %eax,%eax
        \\    jnz __cp_cancel
        \\    mov %rsi,%rdi
        \\    mov %rdx,%rsi
        \\    mov %rcx,%rdx
        \\    mov %r8,%rcx
        \\    mov %r9,%r8
        \\    mov 8(%rsp),%r9
        \\    mov 16(%rsp),%rax
        \\    push %rax
        \\    call __orange_syscall
        \\    add $8,%rsp
        \\__cp_end:
        \\    ret
        \\__cp_cancel:
        \\    jmp __cancel
        \\
        \\.global __restore_rt
        \\.hidden __restore_rt
        \\.type __restore_rt,@function
        \\.global __restore
        \\.hidden __restore
        \\.type __restore,@function
        \\__restore_rt:
        \\__restore:
        \\    movq %rsp,%rdi
        \\    movl $154,%eax
        \\    syscall
        \\    ud2
        \\
        \\.global __unmapself
        \\.type __unmapself,@function
        \\__unmapself:
        \\    movl $11,%eax
        \\    syscall
        \\    xor %edi,%edi
        \\    movl $41,%eax
        \\    syscall
        \\    ud2
    );
}
