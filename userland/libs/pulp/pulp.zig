//! Pulp — the Orange OS C library.
//!
//! Everything a ring 3 program needs that is not the kernel: syscall wrappers,
//! string handling, formatted output, and an allocator. Programs import this
//! instead of writing `syscall` by hand.
//!
//! There is no libc underneath. Pulp *is* the bottom.

const std = @import("std");

// ── Syscall numbers — must match kernel/syscall/syscall.zig ─────────────────

pub const NR = struct {
    pub const exit: u64 = 0;
    pub const write: u64 = 1;
    pub const getpid: u64 = 4;
    pub const yield: u64 = 7;
    pub const spawn: u64 = 8;
    pub const wait: u64 = 9;
    pub const sleep_ms: u64 = 61;
    pub const open: u64 = 20;
    pub const close: u64 = 21;
    pub const read: u64 = 22;
    pub const readdir: u64 = 34;
    pub const port_create: u64 = 50;
    pub const port_connect: u64 = 51;
    pub const port_send: u64 = 52;
    pub const port_recv: u64 = 53;
    pub const shm_create: u64 = 54;
    pub const shm_map: u64 = 55;
    pub const handle_close: u64 = 56;
    pub const shm_open: u64 = 57;
    pub const pty_create: u64 = 80;
    pub const pty_read: u64 = 81;
    pub const pty_write: u64 = 82;
    pub const spawn_pty: u64 = 83;
    pub const net_ping: u64 = 90;
    pub const net_info: u64 = 91;
    pub const fb_acquire: u64 = 70;
    pub const fb_map: u64 = 71;
    pub const input_read: u64 = 72;
    pub const uptime: u64 = 60;
};

pub const STDIN: u64 = 0;
pub const STDOUT: u64 = 1;
pub const STDERR: u64 = 2;

// ── Raw syscall entry ───────────────────────────────────────────────────────
// Arguments go in rdi, rsi, rdx, r10, r8, r9. Not rcx: the `syscall`
// instruction overwrites it with the return address.

pub inline fn syscall0(nr: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall1(nr: u64, a0: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall2(nr: u64, a0: u64, a1: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : "rcx", "r11", "memory"
    );
}

pub inline fn syscall4(nr: u64, a0: u64, a1: u64, a2: u64, a3: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
          [a3] "{r10}" (a3),
        : "rcx", "r11", "memory"
    );
}

// ── Errors ──────────────────────────────────────────────────────────────────

pub const Error = error{
    NotFound,
    IoError,
    BadFd,
    NoMemory,
    TooManyOpen,
    IsDirectory,
    NameTooLong,
    Fault,
    Unknown,
};

fn errno(v: i64) Error {
    return switch (-v) {
        2 => Error.NotFound,
        5 => Error.IoError,
        9 => Error.BadFd,
        12 => Error.NoMemory,
        14 => Error.Fault,
        21 => Error.IsDirectory,
        24 => Error.TooManyOpen,
        36 => Error.NameTooLong,
        else => Error.Unknown,
    };
}

// ── Process ─────────────────────────────────────────────────────────────────

pub fn exit(code: u8) noreturn {
    _ = syscall1(NR.exit, code);
    unreachable;
}

pub fn getpid() i64 {
    return syscall0(NR.getpid);
}

pub fn yield() void {
    _ = syscall0(NR.yield);
}

pub fn uptimeMs() u64 {
    const v = syscall0(NR.uptime);
    return if (v < 0) 0 else @intCast(v);
}

/// Start a program and return its pid.
pub fn spawn(path: []const u8) Error!i64 {
    const r = syscall2(NR.spawn, @intFromPtr(path.ptr), path.len);
    if (r < 0) return errno(r);
    return r;
}

/// Wait for a pid, returning its exit code. Blocks.
pub fn wait(pid: i64) Error!i64 {
    const r = syscall2(NR.wait, @bitCast(pid), 0);
    if (r < 0) return errno(r);
    return r;
}

/// Non-blocking wait. Returns null if the process is still running.
///
/// A supervisor with several services must use this: blocking on each in turn
/// means one long-running service stops it noticing that any other has died.
pub fn waitNoHang(pid: i64) Error!?i64 {
    const r = syscall2(NR.wait, @bitCast(pid), 1);
    if (r == -11) return null; // EAGAIN: still running
    if (r < 0) return errno(r);
    return r;
}

pub fn sleepMs(ms: u64) void {
    _ = syscall1(NR.sleep_ms, ms);
}

// ── I/O ─────────────────────────────────────────────────────────────────────

pub fn write(fd: u64, bytes: []const u8) Error!usize {
    const r = syscall3(NR.write, fd, @intFromPtr(bytes.ptr), bytes.len);
    if (r < 0) return errno(r);
    return @intCast(r);
}

pub fn read(fd: u64, buf: []u8) Error!usize {
    const r = syscall3(NR.read, fd, @intFromPtr(buf.ptr), buf.len);
    if (r < 0) return errno(r);
    return @intCast(r);
}

pub fn open(path: []const u8) Error!i64 {
    const r = syscall2(NR.open, @intFromPtr(path.ptr), path.len);
    if (r < 0) return errno(r);
    return r;
}

pub fn close(fd: i64) void {
    _ = syscall1(NR.close, @bitCast(fd));
}

/// One directory entry, as the kernel hands it back.
pub const DirEntry = extern struct {
    inode: u32,
    type: u8,
    name_len: u8,
    name: [128]u8,

    pub fn nameSlice(self: *const DirEntry) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn isDir(self: *const DirEntry) bool {
        return self.type == 2;
    }
};

/// Read up to `out.len` entries from a directory. Returns how many.
pub fn readdir(path: []const u8, out: []DirEntry) Error!usize {
    const r = syscall4(
        NR.readdir,
        @intFromPtr(path.ptr),
        path.len,
        @intFromPtr(out.ptr),
        out.len,
    );
    if (r < 0) return errno(r);
    return @intCast(r);
}

// ── IPC ─────────────────────────────────────────────────────────────────────
//
// Handles are capabilities: opaque integers, valid only in the process holding
// them, with nothing to guess or forge. A process starts with none.

pub const MAX_PAYLOAD: usize = 4096;

/// Create a named port. Returns a handle.
pub fn portCreate(name: []const u8) Error!i64 {
    const r = syscall2(NR.port_create, @intFromPtr(name.ptr), name.len);
    if (r < 0) return errno(r);
    return r;
}

/// Obtain a handle to an existing port.
pub fn portConnect(name: []const u8) Error!i64 {
    const r = syscall2(NR.port_connect, @intFromPtr(name.ptr), name.len);
    if (r < 0) return errno(r);
    return r;
}

/// Queue a message. Returns its sequence number.
pub fn portSend(h: i64, opcode: u32, payload: []const u8) Error!u64 {
    const r = syscall4(
        NR.port_send,
        @bitCast(h),
        opcode,
        @intFromPtr(payload.ptr),
        payload.len,
    );
    if (r < 0) return errno(r);
    return @intCast(r);
}

pub const Received = struct {
    opcode: u32,
    len: usize,
};

/// Receive a message with its opcode. Blocks by default.
pub fn portRecvMsg(h: i64, buf: []u8, blocking: bool) Error!Received {
    const r = syscall4(
        NR.port_recv,
        @bitCast(h),
        @intFromPtr(buf.ptr),
        buf.len,
        if (blocking) 1 else 0,
    );
    if (r < 0) return errno(r);
    const v: u64 = @bitCast(r);
    return .{ .opcode = @truncate(v >> 32), .len = @intCast(v & 0xFFFF_FFFF) };
}

/// Receive, discarding the opcode.
pub fn portRecv(h: i64, buf: []u8, blocking: bool) Error!usize {
    const r = try portRecvMsg(h, buf, blocking);
    return r.len;
}

/// Allocate a named shared buffer. An empty name makes it private.
pub fn shmCreate(name: []const u8, size: usize) Error!i64 {
    const r = syscall3(NR.shm_create, @intFromPtr(name.ptr), name.len, size);
    if (r < 0) return errno(r);
    return r;
}

/// Get a handle to a shared buffer someone else created.
pub fn shmOpen(name: []const u8) Error!i64 {
    const r = syscall2(NR.shm_open, @intFromPtr(name.ptr), name.len);
    if (r < 0) return errno(r);
    return r;
}

/// Map shared memory into this process. Returns the address.
pub fn shmMap(h: i64, writable: bool) Error![*]u8 {
    const r = syscall2(NR.shm_map, @bitCast(h), if (writable) 1 else 0);
    if (r < 0) return errno(r);
    return @ptrFromInt(@as(u64, @bitCast(r)));
}

pub fn handleClose(h: i64) void {
    _ = syscall1(NR.handle_close, @bitCast(h));
}

// ── Display and input ───────────────────────────────────────────────────────

pub const FbInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    red_shift: u8,
    green_shift: u8,
    blue_shift: u8,
    reserved: u8,
};

pub const EV_KEY: u8 = 1;
pub const EV_MOUSE: u8 = 2;

pub const InputEvent = extern struct {
    kind: u8,
    /// key: scancode. mouse: button bitmask (1 left, 2 right, 4 middle).
    code: u8,
    /// key: bit 0 pressed, bit 1 extended.
    value: u8,
    reserved: u8,
    dx: i32,
    dy: i32,

    pub fn isPress(self: *const InputEvent) bool {
        return self.value & 1 != 0;
    }
};

/// Claim the screen. Only one process may hold it.
pub fn fbAcquire() Error!FbInfo {
    var info: FbInfo = undefined;
    const r = syscall1(NR.fb_acquire, @intFromPtr(&info));
    if (r < 0) return errno(r);
    return info;
}

/// Map the framebuffer. Requires fbAcquire first.
pub fn fbMap() Error![*]u32 {
    const r = syscall0(NR.fb_map);
    if (r < 0) return errno(r);
    return @ptrFromInt(@as(u64, @bitCast(r)));
}

/// Drain pending input events. Returns how many were read.
pub fn inputRead(out: []InputEvent) usize {
    const r = syscall2(NR.input_read, @intFromPtr(out.ptr), out.len);
    if (r < 0) return 0;
    return @intCast(r);
}

// ── Pseudo-terminals ────────────────────────────────────────────────────────

/// Create a PTY. Returns the master handle; the slave is bound to whatever
/// spawnPty starts.
pub fn ptyCreate() Error!i64 {
    const r = syscall0(NR.pty_create);
    if (r < 0) return errno(r);
    return r;
}

/// Read what the program on the slave end has written. Non-blocking.
pub fn ptyRead(h: i64, buf: []u8) usize {
    const r = syscall3(NR.pty_read, @bitCast(h), @intFromPtr(buf.ptr), buf.len);
    if (r < 0) return 0;
    return @intCast(r);
}

/// Supply input the program on the slave end will read from stdin.
pub fn ptyWrite(h: i64, bytes: []const u8) usize {
    const r = syscall3(NR.pty_write, @bitCast(h), @intFromPtr(bytes.ptr), bytes.len);
    if (r < 0) return 0;
    return @intCast(r);
}

/// Start a program with its stdio bound to a PTY.
pub fn spawnPty(path: []const u8, h: i64) Error!i64 {
    const r = syscall3(NR.spawn_pty, @intFromPtr(path.ptr), path.len, @bitCast(h));
    if (r < 0) return errno(r);
    return r;
}

// ── Networking ──────────────────────────────────────────────────────────────

pub const NetInfo = extern struct {
    ip: u32,
    gateway: u32,
    netmask: u32,
    up: u32,
    mac: [6]u8,
    reserved: [2]u8,
};

pub fn netInfo() Error!NetInfo {
    var info: NetInfo = undefined;
    const r = syscall1(NR.net_info, @intFromPtr(&info));
    if (r < 0) return errno(r);
    return info;
}

/// One ICMP echo request. Returns the round trip in microseconds, or null if
/// nothing came back.
pub fn ping(ip: [4]u8, seq: u16, timeout_ms: u64) ?u64 {
    const packed_ip: u64 = @as(u64, ip[0]) | (@as(u64, ip[1]) << 8) |
        (@as(u64, ip[2]) << 16) | (@as(u64, ip[3]) << 24);
    const r = syscall3(NR.net_ping, packed_ip, seq, timeout_ms);
    if (r < 0) return null;
    return @intCast(r);
}

pub fn unpackIp(v: u32) [4]u8 {
    return .{
        @truncate(v),
        @truncate(v >> 8),
        @truncate(v >> 16),
        @truncate(v >> 24),
    };
}

// ── Convenience output ──────────────────────────────────────────────────────

pub fn puts(s: []const u8) void {
    _ = write(STDOUT, s) catch {};
}

pub fn eputs(s: []const u8) void {
    _ = write(STDERR, s) catch {};
}

/// Formatted output. The 1 KiB line buffer is deliberate: a userland program
/// that needs more than that per call should be writing in chunks.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        puts("<format error>\n");
        return;
    };
    puts(s);
}

// ── Allocator ───────────────────────────────────────────────────────────────
// A bump allocator over a static arena. There is no brk or mmap syscall yet,
// so the arena is part of the program's .bss and its size is fixed at link
// time. Freeing is a no-op; programs here are short-lived.

const ARENA_SIZE = 256 * 1024;
var arena: [ARENA_SIZE]u8 align(16) = undefined;
var arena_used: usize = 0;

pub fn alloc(n: usize) Error![]u8 {
    const aligned = (arena_used + 15) & ~@as(usize, 15);
    if (aligned + n > ARENA_SIZE) return Error.NoMemory;
    arena_used = aligned + n;
    return arena[aligned .. aligned + n];
}

pub fn resetArena() void {
    arena_used = 0;
}

pub fn arenaUsed() usize {
    return arena_used;
}

// ── Line input ──────────────────────────────────────────────────────────────

/// Read one line from stdin with echo and backspace handling.
/// Returns the line without its terminator, or null on EOF.
pub fn readLine(buf: []u8) ?[]const u8 {
    var len: usize = 0;
    var ch: [1]u8 = undefined;

    while (true) {
        const n = read(STDIN, &ch) catch return null;
        if (n == 0) continue;
        const c = ch[0];

        switch (c) {
            '\r', '\n' => {
                puts("\n");
                return buf[0..len];
            },
            // Backspace and DEL both arrive depending on the terminal.
            0x08, 0x7F => {
                if (len > 0) {
                    len -= 1;
                    // Erase visually: back up, overwrite with a space, back up.
                    puts("\x08 \x08");
                }
            },
            // Ctrl-C: abandon the line.
            0x03 => {
                puts("^C\n");
                return buf[0..0];
            },
            else => {
                if (c >= 0x20 and c < 0x7F and len < buf.len) {
                    buf[len] = c;
                    len += 1;
                    _ = write(STDOUT, ch[0..1]) catch {};
                }
            },
        }
    }
}

// ── String helpers ──────────────────────────────────────────────────────────

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

/// Split on spaces, writing slices into `out`. Returns the token count.
pub fn tokenize(line: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len) break;
        const start = i;
        while (i < line.len and line[i] != ' ') i += 1;
        out[n] = line[start..i];
        n += 1;
    }
    return n;
}
