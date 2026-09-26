//! The kernel's cryptographically secure random number generator.
//!
//! Entropy comes from:
//! - RDSEED/RDRAND, when the CPU has them (real hardware usually does; QEMU's
//!   default model does not). Their output is credited in full, as Linux does
//!   with a trusted CPU.
//! - Interrupt timing. Each CPU folds the timestamp counter of every hardware
//!   interrupt into a small accumulator of its own, lock-free. Every 64
//!   interrupts the accumulator is hashed into the global pool and credited
//!   one bit (Linux's "fast pool" rate).
//! - Boot time and other uncredited material.
//!
//! The pool is a BLAKE2s state. Once 256 bits are credited, its digest keys a
//! ChaCha20 generator, which is reseeded as more entropy arrives. Output uses
//! fast key erasure: every request ends by replacing the key with fresh
//! keystream, so later compromise does not reveal earlier output. Until the
//! first seeding the generator is not ready: `fill` blocks, and callers that
//! asked not to wait get WouldBlock (or, for /dev/urandom and GRND_INSECURE,
//! bytes from the pool as it stands).

const std = @import("std");
const spinlock = @import("../sync/spinlock.zig");
const percpu = @import("../arch/x86_64/percpu.zig");
const sched = @import("../sched/sched.zig");

const Blake2s = std.crypto.hash.blake2.Blake2s256;
const ChaCha = std.crypto.stream.chacha.ChaCha20IETF;

/// Bits of credited entropy needed before output is considered secure.
const READY_BITS = 256;
/// Interrupts folded per credited bit.
const INTERRUPTS_PER_BIT = 64;

var lock: spinlock.SpinLock = .{};
var pool: Blake2s = Blake2s.init(.{});
var credited: u32 = 0;
var ready: bool = false;
var key: [32]u8 = [_]u8{0} ** 32;
var nonce_counter: u64 = 0;

const FastPool = struct {
    state: [4]u64 = .{ 0x243f6a8885a308d3, 0x13198a2e03707344, 0xa4093822299f31d0, 0x082efa98ec4e6c89 },
    count: u32 = 0,
};
var fast_pools: [percpu.MAX_CPUS]FastPool = [_]FastPool{.{}} ** percpu.MAX_CPUS;

fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

/// One hardware random word, or null when the instruction is missing or
/// keeps failing. RDSEED is preferred: it is meant for seeding.
fn hardwareWord(use_seed: bool) ?u64 {
    for (0..10) |_| {
        var value: u64 = undefined;
        var ok: u8 = undefined;
        if (use_seed) {
            asm volatile ("rdseed %[value]; setc %[ok]"
                : [value] "=r" (value),
                  [ok] "=r" (ok),
                :
                : "cc"
            );
        } else {
            asm volatile ("rdrand %[value]; setc %[ok]"
                : [value] "=r" (value),
                  [ok] "=r" (ok),
                :
                : "cc"
            );
        }
        if (ok != 0) return value;
    }
    return null;
}

pub const Source = enum { hardware, interrupts };
var source: Source = .interrupts;

/// Seed from whatever is available at boot.
pub fn init(boot_material: []const u8) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    pool.update(boot_material);
    const tsc = rdtsc();
    pool.update(std.mem.asBytes(&tsc));
    const has_rdrand = cpuid(1, 0)[2] & (1 << 30) != 0;
    const has_rdseed = cpuid(0, 0)[0] >= 7 and cpuid(7, 0)[1] & (1 << 18) != 0;
    if (has_rdseed or has_rdrand) {
        var gathered: u32 = 0;
        for (0..8) |_| {
            const word = hardwareWord(has_rdseed) orelse hardwareWord(false) orelse break;
            pool.update(std.mem.asBytes(&word));
            gathered += 64;
        }
        if (gathered >= READY_BITS) {
            credited = gathered;
            source = .hardware;
        }
    }
    if (credited >= READY_BITS) reseedLocked();
}

pub fn sourceName() []const u8 {
    return @tagName(source);
}

/// Caller holds the lock: key the generator from the pool.
fn reseedLocked() void {
    var fork = pool;
    fork.update(&key);
    fork.final(&key);
    // Keep the pool chained to what it produced.
    pool.update(&key);
    if (!ready) {
        ready = true;
        sched.wakeChannel(channel());
    }
}

fn channel() usize {
    return @intFromPtr(&ready);
}

pub fn isReady() bool {
    return @atomicLoad(bool, &ready, .acquire);
}

/// Called from every hardware interrupt, with interrupts masked.
pub fn mixInterrupt(vector: u8) void {
    const fast = &fast_pools[percpu.cpuIndex()];
    const tsc = rdtsc();
    fast.state[0] = std.math.rotl(u64, fast.state[0] ^ tsc, 17) +% fast.state[1];
    fast.state[1] = std.math.rotl(u64, fast.state[1] ^ vector, 29) +% fast.state[2];
    fast.state[2] = std.math.rotl(u64, fast.state[2] +% fast.state[0], 41) ^ fast.state[3];
    fast.state[3] = std.math.rotl(u64, fast.state[3] +% tsc, 7) ^ fast.state[1];
    fast.count += 1;
    if (fast.count < INTERRUPTS_PER_BIT) return;
    fast.count = 0;
    lock.acquire();
    defer lock.release();
    pool.update(std.mem.sliceAsBytes(&fast.state));
    if (credited < std.math.maxInt(u32)) credited += 1;
    // Reseed at readiness, then after each further 256 bits.
    if (credited % READY_BITS == 0) reseedLocked();
}

/// Mix caller-provided bytes into the pool without crediting them (writes
/// to /dev/random).
pub fn mixUncredited(bytes: []const u8) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    pool.update(bytes);
}

/// Generator output, with fast key erasure. Caller holds the lock.
fn generateLocked(out: []u8) void {
    var nonce: [12]u8 = [_]u8{0} ** 12;
    std.mem.writeInt(u64, nonce[0..8], nonce_counter, .little);
    nonce_counter +%= 1;
    ChaCha.stream(out, 1, key, nonce);
    var next: [32]u8 = undefined;
    ChaCha.stream(&next, 0, key, nonce);
    key = next;
}

pub const Error = error{ WouldBlock, Interrupted };

pub const Wait = enum { block, fail, insecure };

/// Fill `out` with random bytes. Before the first seeding: `block` waits
/// (call with interrupts enabled), `fail` returns WouldBlock, `insecure`
/// returns output keyed from the pool as it stands.
pub fn fill(out: []u8, wait: Wait) Error!void {
    while (!isReady()) {
        switch (wait) {
            .fail => return Error.WouldBlock,
            .insecure => {
                const state = spinlock.acquireIrqSave(&lock);
                defer spinlock.releaseIrqRestore(&lock, state);
                var fork = pool;
                var provisional: [32]u8 = undefined;
                fork.final(&provisional);
                var nonce: [12]u8 = [_]u8{0} ** 12;
                std.mem.writeInt(u64, nonce[0..8], nonce_counter, .little);
                nonce_counter +%= 1;
                ChaCha.stream(out, 1, provisional, nonce);
                return;
            },
            .block => {
                sched.prepareWait(channel());
                if (isReady()) {
                    sched.cancelWait();
                    break;
                }
                if (sched.killPending()) {
                    sched.cancelWait();
                    return Error.Interrupted;
                }
                sched.commitWait();
            },
        }
    }
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    generateLocked(out);
}

pub const Stats = struct { credited_bits: u32, ready: bool, source: Source };

pub fn stats() Stats {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return .{ .credited_bits = credited, .ready = ready, .source = source };
}
