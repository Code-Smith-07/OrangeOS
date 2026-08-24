//! Orange OS — first userspace program.
//!
//! Runs in ring 3 with no libc. Every interaction with the kernel goes through
//! the `syscall` instruction. Pulp (the C library) will wrap these in Phase 6;
//! for now the stubs are written out by hand so the ABI is visible.

const NR_EXIT: u64 = 0;
const NR_WRITE: u64 = 1;
const NR_GETPID: u64 = 4;
const NR_YIELD: u64 = 7;
const NR_UPTIME: u64 = 60;

/// Argument registers are rdi, rsi, rdx, r10, r8, r9 — r10 rather than rcx,
/// because the `syscall` instruction overwrites rcx with the return address.
inline fn syscall0(nr: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall1(nr: u64, a0: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
        : "rcx", "r11", "memory"
    );
}

inline fn syscall3(nr: u64, a0: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> i64),
        : [nr] "{rax}" (nr),
          [a0] "{rdi}" (a0),
          [a1] "{rsi}" (a1),
          [a2] "{rdx}" (a2),
        : "rcx", "r11", "memory"
    );
}

fn write(s: []const u8) i64 {
    return syscall3(NR_WRITE, 1, @intFromPtr(s.ptr), s.len);
}

fn exit(code: u64) noreturn {
    _ = syscall1(NR_EXIT, code);
    unreachable;
}

/// Minimal unsigned-to-decimal, since there is no libc yet.
fn writeNum(buf: []u8, value: u64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var v = value;
    while (v > 0) : (v /= 10) {
        digits[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) buf[i] = digits[n - 1 - i];
    return buf[0..n];
}

export fn _start() callconv(.c) noreturn {
    _ = write("\n");
    _ = write("  +--------------------------------------------+\n");
    _ = write("  |   Hello from ring 3.                       |\n");
    _ = write("  |   This process cannot touch kernel memory. |\n");
    _ = write("  +--------------------------------------------+\n");

    var buf: [32]u8 = undefined;

    const pid = syscall0(NR_GETPID);
    _ = write("  getpid()  -> ");
    _ = write(writeNum(&buf, @intCast(pid)));
    _ = write("\n");

    const up = syscall0(NR_UPTIME);
    _ = write("  uptime()  -> ");
    _ = write(writeNum(&buf, @intCast(up)));
    _ = write(" ms\n");

    // Prove the kernel rejects a pointer into its own address space rather
    // than dereferencing it. A kernel that skips validation would either
    // leak memory contents here or fault in ring 0.
    const kernel_addr: u64 = 0xFFFF_FFFF_8000_0000;
    const bad = syscall3(NR_WRITE, 1, kernel_addr, 64);
    _ = write("  write(kernel ptr) -> ");
    if (bad < 0) {
        _ = write("-");
        _ = write(writeNum(&buf, @intCast(-bad)));
        _ = write(" (EFAULT, rejected)\n");
    } else {
        _ = write("ACCEPTED - VALIDATION IS BROKEN\n");
    }

    // Same for a user-half pointer that simply is not mapped.
    const unmapped: u64 = 0x0000_7000_0000_0000;
    const bad2 = syscall3(NR_WRITE, 1, unmapped, 16);
    _ = write("  write(unmapped)   -> ");
    if (bad2 < 0) {
        _ = write("-");
        _ = write(writeNum(&buf, @intCast(-bad2)));
        _ = write(" (EFAULT, rejected)\n");
    } else {
        _ = write("ACCEPTED - VALIDATION IS BROKEN\n");
    }

    _ = write("  yielding to the scheduler...\n");
    _ = syscall0(NR_YIELD);
    _ = write("  resumed after yield.\n\n");

    exit(0);
}
