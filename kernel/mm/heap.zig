//! Kernel heap — kalloc / kfree.
//!
//! Requests up to 2 KiB are routed to the nearest power-of-two slab cache.
//! Anything larger goes straight to the buddy allocator, page-aligned.
//!
//! Every allocation carries a 16-byte header recording its size class, so
//! kfree knows where to return it without the caller tracking anything.

const std = @import("std");
const spinlock = @import("../sync/spinlock.zig");
const pmm = @import("pmm.zig");
const slab = @import("slab.zig");
const console = @import("../console.zig");
const fmt = @import("../lib/fmt.zig");

pub const Error = error{OutOfMemory};

/// Size classes: 16 B through 2 KiB.
const SIZE_CLASSES = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const MAX_SLAB_SIZE = SIZE_CLASSES[SIZE_CLASSES.len - 1];

var caches: [SIZE_CLASSES.len]slab.Cache = undefined;
var initialized = false;

/// Precedes every allocation. 16 bytes keeps the payload 16-byte aligned,
/// which the SysV ABI requires for anything holding a wide type.
const Header = extern struct {
    /// LIVE while allocated. Freeing hands the block back to the slab or
    /// buddy allocator, which keep their free-list links in these very bytes,
    /// so a second free of the same object, or a free of a pointer the heap
    /// never returned, is caught instead of corrupting a cache.
    magic: u32,
    /// Index into SIZE_CLASSES, or SLAB_NONE for a direct buddy allocation.
    class: u32,
    /// Buddy order, only meaningful for direct allocations.
    order: u64,
};

const LIVE: u32 = 0x4556_494C; // "LIVE"
const SLAB_NONE: u32 = std.math.maxInt(u32);
const HEADER_SIZE = @sizeOf(Header);
/// Written over freed payloads in safety-checked builds: a later read through
/// a stale pointer then trips a safety check or a non-canonical address.
const POISON: u8 = 0xDF;

pub fn init() void {
    const names = [_][]const u8{
        "kmalloc-16",   "kmalloc-32",   "kmalloc-64",   "kmalloc-128",
        "kmalloc-256",  "kmalloc-512",  "kmalloc-1024", "kmalloc-2048",
    };
    for (SIZE_CLASSES, 0..) |size, i| {
        caches[i] = slab.Cache.init(names[i], size);
    }
    initialized = true;
}

fn classFor(size: usize) ?usize {
    for (SIZE_CLASSES, 0..) |cls, i| {
        if (size <= cls) return i;
    }
    return null;
}

/// Guards the slab caches.
///
/// Cache.alloc pops the head of a free list and writes the new head back,
/// with no atomics anywhere in between - the same shape of race that was
/// corrupting the buddy allocator. The heap is reachable from every subsystem
/// on every core, so it needs the same discipline.
///
/// Lock order is heap -> pmm, never the reverse: the heap falls through to the
/// page allocator for large requests, and the page allocator never calls back
/// into the heap.
var lock: spinlock.SpinLock = .{};

/// Allocate `size` bytes. Returns a 16-byte-aligned pointer.
pub fn alloc(size: usize) Error![*]u8 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return allocUnlocked(size);
}

fn allocUnlocked(size: usize) Error![*]u8 {
    std.debug.assert(initialized);
    if (size == 0) return Error.OutOfMemory;

    const total = size + HEADER_SIZE;

    if (classFor(total)) |ci| {
        const raw = caches[ci].alloc() catch return Error.OutOfMemory;
        const hdr: *Header = @ptrCast(@alignCast(raw));
        hdr.* = .{ .magic = LIVE, .class = @intCast(ci), .order = 0 };
        return raw + HEADER_SIZE;
    }

    // Too big for a slab: take whole pages from the buddy allocator.
    const pages = (total + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const order = pmm.orderFor(pages);
    const phys = pmm.allocOrder(order) catch return Error.OutOfMemory;
    const virt = pmm.physToVirt(phys);
    const hdr: *Header = @ptrFromInt(virt);
    hdr.* = .{ .magic = LIVE, .class = SLAB_NONE, .order = order };
    return @as([*]u8, @ptrFromInt(virt)) + HEADER_SIZE;
}

/// Allocate and zero.
pub fn allocZeroed(size: usize) Error![*]u8 {
    const p = try alloc(size);
    @memset(p[0..size], 0);
    return p;
}

/// Typed convenience wrapper.
pub fn create(comptime T: type) Error!*T {
    const p = try alloc(@sizeOf(T));
    return @ptrCast(@alignCast(p));
}

pub fn destroy(ptr: anytype) void {
    freeFrom(@ptrCast(@alignCast(ptr)), @returnAddress());
}

pub fn free(ptr: [*]u8) void {
    freeFrom(ptr, @returnAddress());
}

fn freeFrom(ptr: [*]u8, caller: usize) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    freeUnlocked(ptr, caller);
}

fn freeUnlocked(ptr: [*]u8, caller: usize) void {
    const raw = ptr - HEADER_SIZE;
    const hdr: *Header = @ptrCast(@alignCast(raw));
    if (hdr.magic != LIVE or (hdr.class != SLAB_NONE and hdr.class >= SIZE_CLASSES.len)) {
        @branchHint(.cold);
        const words: *const [2]u64 = @ptrCast(hdr);
        var line: [160]u8 = undefined;
        console.emergencyWrite(fmt.bufPrint(&line, "HEAP invalid free: object 0x{x:0>16} header 0x{x:0>16} 0x{x:0>16} caller 0x{x:0>16}\n", .{ @intFromPtr(ptr), words[0], words[1], caller }));
        @panic("heap: free of an object that is not live (double free or foreign pointer)");
    }
    hdr.magic = 0;

    if (hdr.class == SLAB_NONE) {
        if (std.debug.runtime_safety) @memset(ptr[0 .. (pmm.PAGE_SIZE << @intCast(hdr.order)) - HEADER_SIZE], POISON);
        const phys = pmm.virtToPhys(@intFromPtr(raw));
        pmm.freeOrder(phys, @intCast(hdr.order));
        return;
    }

    if (std.debug.runtime_safety) {
        @memset(ptr[0 .. SIZE_CLASSES[hdr.class] - HEADER_SIZE], POISON);
        // Who freed it: a use after free that reads this word can name them.
        @as(*align(1) usize, @ptrCast(ptr)).* = caller;
    }
    caches[hdr.class].free(raw);
}

pub const Stats = struct {
    slab_allocated: usize,
    slab_total: usize,
};

pub fn stats() Stats {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    var allocated: usize = 0;
    var total: usize = 0;
    for (&caches) |*c| {
        allocated += c.allocated;
        total += c.total_objects;
    }
    return .{ .slab_allocated = allocated, .slab_total = total };
}

pub fn cacheReport() []const slab.Cache {
    return &caches;
}
