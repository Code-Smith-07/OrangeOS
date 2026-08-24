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
    pub const open: u64 = 20;
    pub const close: u64 = 21;
    pub const read: u64 = 22;
    pub const readdir: u64 = 34;
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

/// Wait for a pid, returning its exit code.
pub fn wait(pid: i64) Error!i64 {
    const r = syscall1(NR.wait, @bitCast(pid));
    if (r < 0) return errno(r);
    return r;
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
