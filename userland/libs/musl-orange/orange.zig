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
    const NOTDIR = 20;
    const INVAL = 22;
    const NOTTY = 25;
    const SPIPE = 29;
    const ROFS = 30;
    const NOSYS = 38;
    const TIMEDOUT = 110;
};

fn err(code: i64) i64 {
    return -code;
}

const AT_FDCWD: i64 = -100;
const AT_EMPTY_PATH: u64 = 0x1000;
const O_ACCMODE: u64 = 3;
const O_CREAT: u64 = 0o100;
const O_TRUNC: u64 = 0o1000;
const O_APPEND: u64 = 0o2000;

// ── Helpers ─────────────────────────────────────────────────────────────────

fn cString(address: u64) ?[]const u8 {
    if (address == 0) return null;
    const pointer: [*:0]const u8 = @ptrFromInt(address);
    return std.mem.span(pointer);
}

/// Resolve a path relative to the (fixed) working directory "/".
fn absolute(path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') return path;
    if (path.len + 1 > buffer.len) return null;
    buffer[0] = '/';
    @memcpy(buffer[1 .. path.len + 1], path);
    return buffer[0 .. path.len + 1];
}

const Status = extern struct { size: u64, kind: u32, reserved: u32 };

const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;
const S_IFCHR: u32 = 0o020000;

fn modeOf(kind: u32) u32 {
    return switch (kind) {
        2 => S_IFDIR | 0o755,
        3 => S_IFCHR | 0o620,
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
    if (path[0] != '/' and dirfd != AT_FDCWD) return err(E.NOSYS);
    const full = absolute(path, &buffer) orelse return err(E.NOENT);
    return raw3(OR.stat, @intFromPtr(full.ptr), full.len, @intFromPtr(out));
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

export fn __orange_syscall(n: i64, a1: i64, a2: i64, a3: i64, a4: i64, a5: i64, a6: i64) callconv(.c) i64 {
    const a: u64 = @bitCast(a1);
    const b: u64 = @bitCast(a2);
    const c: u64 = @bitCast(a3);
    const d: u64 = @bitCast(a4);
    const e: u64 = @bitCast(a5);
    const f: u64 = @bitCast(a6);
    return switch (n) {
        SYS.read => raw3(OR.read, a, b, @min(c, 4096)),
        SYS.write => raw3(OR.write, a, b, @min(c, 4096)),
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
        SYS.access => accessPath(AT_FDCWD, a, b),
        SYS.faccessat => accessPath(a1, b, c),
        SYS.mmap => mmap(a, b, c, d, a5, f),
        SYS.mprotect => blk: {
            const prot = translateProt(c) orelse break :blk err(E.ACCES);
            break :blk raw3(OR.mprotect, a, b, prot);
        },
        SYS.munmap => raw2(OR.munmap, a, b),
        // No program break: musl's allocator then uses mmap alone.
        SYS.brk => 0,
        SYS.mremap => err(E.NOMEM),
        // Advice only; MADV_DONTNEED's zero-fill guarantee is not offered.
        SYS.madvise => if (c == 4) err(E.NOSYS) else 0,
        SYS.rt_sigaction => err(E.NOSYS),
        // No signal is ever delivered, so every mask is equivalent.
        SYS.rt_sigprocmask => blk: {
            if (c != 0) @as(*u64, @ptrFromInt(c)).* = 0;
            break :blk 0;
        },
        SYS.ioctl => ioctl(a, b, c),
        SYS.fcntl => fcntl(a, b),
        SYS.sched_yield => raw0(OR.yield),
        SYS.nanosleep => blk: {
            const ts: *const Timespec = @ptrFromInt(a);
            if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) break :blk err(E.INVAL);
            sleepNs(@as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec)));
            break :blk 0;
        },
        SYS.clock_nanosleep => blk: {
            const ts: *const Timespec = @ptrFromInt(c);
            if (ts.sec < 0 or ts.nsec < 0 or ts.nsec >= 1_000_000_000) break :blk err(E.INVAL);
            var ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
            if (b & 1 != 0) { // TIMER_ABSTIME
                const now = readClock(a1) orelse break :blk err(E.INVAL);
                ns = ns -| now;
            }
            sleepNs(ns);
            break :blk 0;
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
        SYS.getppid => 1,
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
        SYS.getcwd => blk: {
            if (b < 2) break :blk err(34); // ERANGE
            const out: [*]u8 = @ptrFromInt(a);
            out[0] = '/';
            out[1] = 0;
            break :blk 2;
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
    const path = cString(path_address) orelse return err(E.FAULT);
    // The root filesystem is read-only.
    if (flags & O_ACCMODE != 0 or flags & (O_CREAT | O_TRUNC | O_APPEND) != 0) return err(E.ROFS);
    if (path.len > 0 and path[0] != '/' and dirfd != AT_FDCWD) return err(E.NOSYS);
    var buffer: [256]u8 = undefined;
    const full = absolute(path, &buffer) orelse return err(E.NOENT);
    return raw2(OR.open, @intFromPtr(full.ptr), full.len);
}

fn accessPath(dirfd: i64, path_address: u64, mode: u64) i64 {
    var status: Status = undefined;
    const r = statusOf(dirfd, path_address, 0, &status);
    if (r < 0) return r;
    if (mode & 2 != 0) return err(E.ROFS); // W_OK on a read-only filesystem
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

fn mmap(address: u64, length: u64, prot: u64, flags: u64, fd: i64, offset: u64) i64 {
    // Anonymous private memory only; hints are ignored, fixed placement and
    // file mappings are not available yet.
    if (flags & MAP_FIXED != 0) return err(E.NOMEM);
    if (flags & MAP_ANONYMOUS == 0 or fd != -1) return err(19); // ENODEV
    const kind = flags & ~(MAP_NORESERVE | MAP_STACK);
    if (kind != MAP_PRIVATE | MAP_ANONYMOUS) return err(E.INVAL);
    _ = address;
    _ = offset;
    const native = translateProt(prot) orelse return err(E.ACCES);
    return raw6(OR.mmap, 0, length, native, 0x22, std.math.maxInt(u64), 0);
}

fn ioctl(fd: u64, request: u64, argument: u64) i64 {
    // The console and terminals answer TIOCGWINSZ, so stdio line-buffers
    // them; nothing else is a terminal.
    if (request == 0x5413 and fd <= 2) {
        const size: *[4]u16 = @ptrFromInt(argument);
        size.* = .{ 25, 80, 0, 0 };
        return 0;
    }
    return err(E.NOTTY);
}

fn fcntl(fd: u64, command: u64) i64 {
    return switch (command) {
        1 => 0, // F_GETFD
        2 => 0, // F_SETFD: descriptors are never inherited, so close-on-exec holds
        3 => if (fd <= 2) 2 else 0, // F_GETFL: O_RDWR for stdio, O_RDONLY for files
        4 => 0, // F_SETFL
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
// whether a thread is inside the call. OrangeOS delivers no signals, so only
// the check before the call applies. __unmapself removes the calling
// thread's own stack and exits without touching it in between.
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
