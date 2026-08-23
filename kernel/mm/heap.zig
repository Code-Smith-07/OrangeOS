//! Kernel heap — kalloc / kfree.
//!
//! Requests up to 2 KiB are routed to the nearest power-of-two slab cache.
//! Anything larger goes straight to the buddy allocator, page-aligned.
//!
//! Every allocation carries a 16-byte header recording its size class, so
//! kfree knows where to return it without the caller tracking anything.

const std = @import("std");
const pmm = @import("pmm.zig");
const slab = @import("slab.zig");

pub const Error = error{OutOfMemory};

/// Size classes: 16 B through 2 KiB.
const SIZE_CLASSES = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const MAX_SLAB_SIZE = SIZE_CLASSES[SIZE_CLASSES.len - 1];

var caches: [SIZE_CLASSES.len]slab.Cache = undefined;
var initialized = false;

/// Precedes every allocation. 16 bytes keeps the payload 16-byte aligned,
/// which the SysV ABI requires for anything holding a wide type.
const Header = extern struct {
    /// Index into SIZE_CLASSES, or SLAB_NONE for a direct buddy allocation.
    class: u64,
    /// Buddy order, only meaningful for direct allocations.
    order: u64,
};

const SLAB_NONE: u64 = std.math.maxInt(u64);
const HEADER_SIZE = @sizeOf(Header);

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

/// Allocate `size` bytes. Returns a 16-byte-aligned pointer.
pub fn alloc(size: usize) Error![*]u8 {
    std.debug.assert(initialized);
    if (size == 0) return Error.OutOfMemory;

    const total = size + HEADER_SIZE;

    if (classFor(total)) |ci| {
        const raw = caches[ci].alloc() catch return Error.OutOfMemory;
        const hdr: *Header = @ptrCast(@alignCast(raw));
        hdr.* = .{ .class = ci, .order = 0 };
        return raw + HEADER_SIZE;
    }

    // Too big for a slab: take whole pages from the buddy allocator.
    const pages = (total + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const order = pmm.orderFor(pages);
    const phys = pmm.allocOrder(order) catch return Error.OutOfMemory;
    const virt = pmm.physToVirt(phys);
    const hdr: *Header = @ptrFromInt(virt);
    hdr.* = .{ .class = SLAB_NONE, .order = order };
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
    free(@ptrCast(@alignCast(ptr)));
}

pub fn free(ptr: [*]u8) void {
    const raw = ptr - HEADER_SIZE;
    const hdr: *Header = @ptrCast(@alignCast(raw));

    if (hdr.class == SLAB_NONE) {
        const phys = pmm.virtToPhys(@intFromPtr(raw));
        pmm.freeOrder(phys, @intCast(hdr.order));
        return;
    }

    caches[@intCast(hdr.class)].free(raw);
}

pub const Stats = struct {
    slab_allocated: usize,
    slab_total: usize,
};

pub fn stats() Stats {
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
