//! Physical memory manager — buddy allocator.
//!
//! Manages physical page frames in power-of-two blocks, orders 0..10
//! (4 KiB .. 4 MiB). Adjacent free blocks of equal order merge back into the
//! next order up, so contiguous allocations stay obtainable for DMA even after
//! heavy fragmentation.
//!
//! Free blocks store their own list nodes: a free block is by definition not in
//! use, so the first 16 bytes hold prev/next pointers. That costs zero extra
//! memory. Nodes are reached through the HHDM, since the allocator deals in
//! physical addresses but has to write to them.
//!
//! Per-order bitmaps record which blocks are free, which is what makes
//! coalescing O(1): to merge, we need to ask "is my buddy free?" without
//! searching a list.

const std = @import("std");
const spinlock = @import("../sync/spinlock.zig");
const limine = @import("../boot/limine_req.zig");
const console = @import("../console.zig");

pub const PAGE_SIZE: usize = 4096;
pub const MAX_ORDER: usize = 10; // 4 KiB << 10 = 4 MiB
const ORDER_COUNT = MAX_ORDER + 1;

pub const Error = error{
    OutOfMemory,
    InvalidOrder,
};

/// Embedded in the free block itself, reached via the HHDM.
const FreeNode = extern struct {
    prev: ?*FreeNode,
    next: ?*FreeNode,
};

var hhdm_offset: u64 = 0;

/// Physical address range under management. Everything is indexed relative to
/// `base`, so a machine whose RAM starts high doesn't waste bitmap space.
var base: u64 = 0;
var limit: u64 = 0;

var free_lists: [ORDER_COUNT]?*FreeNode = [_]?*FreeNode{null} ** ORDER_COUNT;
var bitmaps: [ORDER_COUNT][]u8 = undefined;

var total_pages: usize = 0;
var free_pages: usize = 0;
var reserved_pages: usize = 0;

// ── Address helpers ──────────────────────────────────────────────────────────

pub inline fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

pub inline fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}

inline fn nodeAt(phys: u64) *FreeNode {
    return @ptrFromInt(physToVirt(phys));
}

inline fn blockSize(order: usize) u64 {
    return @as(u64, PAGE_SIZE) << @intCast(order);
}

/// Index of the block containing `phys` at a given order.
inline fn blockIndex(phys: u64, order: usize) u64 {
    return (phys - base) / blockSize(order);
}

inline fn blockAddr(index: u64, order: usize) u64 {
    return base + index * blockSize(order);
}

// ── Bitmap ───────────────────────────────────────────────────────────────────

inline fn bitGet(order: usize, index: u64) bool {
    const byte = index / 8;
    if (byte >= bitmaps[order].len) return false;
    return (bitmaps[order][byte] >> @intCast(index % 8)) & 1 != 0;
}

inline fn bitSet(order: usize, index: u64) void {
    const byte = index / 8;
    if (byte >= bitmaps[order].len) return;
    bitmaps[order][byte] |= @as(u8, 1) << @intCast(index % 8);
}

inline fn bitClear(order: usize, index: u64) void {
    const byte = index / 8;
    if (byte >= bitmaps[order].len) return;
    bitmaps[order][byte] &= ~(@as(u8, 1) << @intCast(index % 8));
}

// ── Free list ────────────────────────────────────────────────────────────────

fn listPush(order: usize, phys: u64) void {
    const node = nodeAt(phys);
    node.prev = null;
    node.next = free_lists[order];
    if (free_lists[order]) |head| head.prev = node;
    free_lists[order] = node;
    bitSet(order, blockIndex(phys, order));
}

fn listPop(order: usize) ?u64 {
    const node = free_lists[order] orelse return null;
    free_lists[order] = node.next;
    if (node.next) |n| n.prev = null;
    const phys = virtToPhys(@intFromPtr(node));
    bitClear(order, blockIndex(phys, order));
    return phys;
}

/// Unlink a specific block — needed when coalescing pulls a buddy out of the
/// middle of a list. This is why the lists are doubly linked.
fn listRemove(order: usize, phys: u64) void {
    const node = nodeAt(phys);
    if (node.prev) |p| p.next = node.next else free_lists[order] = node.next;
    if (node.next) |n| n.prev = node.prev;
    bitClear(order, blockIndex(phys, order));
}

// ── Allocation ───────────────────────────────────────────────────────────────

/// Guards the free lists, the per-order bitmaps and the page counters.
///
/// The buddy allocator was written single-core and stayed that way through
/// Phase 8, when three more processors started calling into it. Nothing here
/// is atomic: listPop reads free_lists[order], follows a next pointer and
/// writes the head back, and two cores interleaving in that window leave the
/// list pointing at a block that is no longer free - or at a fragment of one.
///
/// That is not theoretical. It showed up as a page fault inside listPop with
/// CR2 holding an address that was not even page-aligned, on two cores at
/// once, once there were enough allocation sites to make the window easy to
/// hit. Every entry point takes this lock with interrupts off, because an
/// interrupt handler that allocates while the interrupted code holds the lock
/// deadlocks the core against itself.
var lock: spinlock.SpinLock = .{};

/// Allocate 2^order contiguous pages. Returns a physical address.
pub fn allocOrder(order: usize) Error!u64 {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return allocOrderUnlocked(order);
}

/// The allocation itself. Callers must already hold `lock`.
fn allocOrderUnlocked(order: usize) Error!u64 {
    if (order > MAX_ORDER) return Error.InvalidOrder;

    // Find the smallest order with something free.
    var o = order;
    while (o <= MAX_ORDER) : (o += 1) {
        if (free_lists[o] != null) break;
    } else return Error.OutOfMemory;

    const phys = listPop(o).?;

    // Split down, returning the upper half of each split to the free list.
    while (o > order) {
        o -= 1;
        const buddy = phys + blockSize(o);
        listPush(o, buddy);
    }

    free_pages -= @as(usize, 1) << @intCast(order);
    return phys;
}

/// Allocate a single 4 KiB page.
pub fn allocPage() Error!u64 {
    return allocOrder(0);
}

/// Allocate 2^order pages, zeroed. Page tables must be zeroed before use.
///
/// The zeroing happens after the lock is dropped. The block belongs to this
/// caller by then, so nobody else can observe it, and holding a spinlock
/// across a memset of up to 4 MiB would stall every other core for the
/// duration of a memory-bandwidth-bound loop.
pub fn allocOrderZeroed(order: usize) Error!u64 {
    const phys = try allocOrder(order);
    const ptr: [*]u8 = @ptrFromInt(physToVirt(phys));
    @memset(ptr[0..blockSize(order)], 0);
    return phys;
}

pub fn allocPageZeroed() Error!u64 {
    return allocOrderZeroed(0);
}

/// Return a block, merging with its buddy as far up as possible.
pub fn freeOrder(phys: u64, order: usize) void {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    freeOrderUnlocked(phys, order);
}

fn freeOrderUnlocked(phys: u64, order: usize) void {
    var addr = phys;
    var o = order;

    while (o < MAX_ORDER) {
        const index = blockIndex(addr, o);
        const buddy_index = index ^ 1; // buddies differ in exactly one bit
        const buddy_addr = blockAddr(buddy_index, o);

        if (buddy_addr >= limit) break;
        if (!bitGet(o, buddy_index)) break; // buddy in use — stop here

        listRemove(o, buddy_addr);
        addr = @min(addr, buddy_addr); // the merged block starts at the lower
        o += 1;
    }

    listPush(o, addr);
    free_pages += @as(usize, 1) << @intCast(order);
}

pub fn freePage(phys: u64) void {
    freeOrder(phys, 0);
}

/// Smallest order that holds at least `pages` pages.
pub fn orderFor(pages: usize) usize {
    var order: usize = 0;
    while ((@as(usize, 1) << @intCast(order)) < pages and order < MAX_ORDER) : (order += 1) {}
    return order;
}

// ── Initialization ───────────────────────────────────────────────────────────

/// Add a usable range, carving it into the largest aligned blocks that fit.
///
/// Physical page 0 is never added. Keeping it out of the allocator is what
/// lets the null page stay unmapped, which is what makes a null dereference a
/// fault rather than a silent read of whatever the firmware left there.
fn addRange(start: u64, end: u64) void {
    var addr = std.mem.alignForward(u64, @max(start, PAGE_SIZE), PAGE_SIZE);
    const stop = std.mem.alignBackward(u64, end, PAGE_SIZE);

    while (addr < stop) {
        // Largest order that is both aligned at `addr` and fits before `stop`.
        var order: usize = MAX_ORDER;
        while (order > 0) : (order -= 1) {
            const size = blockSize(order);
            if (addr % size == 0 and addr + size <= stop) break;
        }
        listPush(order, addr);
        free_pages += @as(usize, 1) << @intCast(order);
        addr += blockSize(order);
    }
}

pub fn init() !void {
    hhdm_offset = limine.hhdmOffset() orelse return error.NoHhdm;
    const mm = limine.memmap() orelse return error.NoMemoryMap;

    // Pass 1: find the physical extent of usable memory.
    var lowest: u64 = std.math.maxInt(u64);
    var highest: u64 = 0;
    var usable_bytes: u64 = 0;

    var i: usize = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
        if (e.type != .usable) continue;
        if (e.base < lowest) lowest = e.base;
        if (e.base + e.length > highest) highest = e.base + e.length;
        usable_bytes += e.length;
    }
    if (highest == 0) return error.NoUsableMemory;

    base = std.mem.alignBackward(u64, lowest, blockSize(MAX_ORDER));
    limit = highest;
    total_pages = @intCast(usable_bytes / PAGE_SIZE);

    // Pass 2: size the bitmaps. One bit per block per order.
    const span = limit - base;
    var bitmap_bytes: usize = 0;
    var order: usize = 0;
    while (order <= MAX_ORDER) : (order += 1) {
        const blocks = (span / blockSize(order)) + 1;
        bitmap_bytes += @intCast((blocks + 7) / 8);
    }
    const bitmap_pages = (bitmap_bytes + PAGE_SIZE - 1) / PAGE_SIZE;

    // Pass 3: bootstrap. Carve bitmap storage out of the first usable region
    // large enough, before any free list exists.
    //
    // Two things to be careful about, both of which only bite on UEFI:
    //
    // A "found" flag rather than testing bitmap_phys against zero. UEFI
    // reports a usable region starting at physical address 0, so a zero
    // sentinel turns a perfectly good region into a failure. BIOS happened to
    // start its first region higher, which is why this never showed up there.
    //
    // Skipping the first page keeps physical page 0 out of the allocator, so
    // the null page stays unmapped and a null dereference still faults.
    var bitmap_phys: u64 = 0;
    var found_bootstrap = false;
    i = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
        if (e.type != .usable) continue;

        const start = @max(e.base, PAGE_SIZE);
        if (start >= e.base + e.length) continue;
        const usable_len = e.base + e.length - start;

        if (usable_len >= bitmap_pages * PAGE_SIZE) {
            bitmap_phys = std.mem.alignForward(u64, start, PAGE_SIZE);
            found_bootstrap = true;
            break;
        }
    }
    if (!found_bootstrap) return error.NoBootstrapRegion;

    const bitmap_all: [*]u8 = @ptrFromInt(physToVirt(bitmap_phys));
    @memset(bitmap_all[0 .. bitmap_pages * PAGE_SIZE], 0);

    var cursor: usize = 0;
    order = 0;
    while (order <= MAX_ORDER) : (order += 1) {
        const blocks = (span / blockSize(order)) + 1;
        const bytes: usize = @intCast((blocks + 7) / 8);
        bitmaps[order] = bitmap_all[cursor .. cursor + bytes];
        cursor += bytes;
    }

    reserved_pages = bitmap_pages;

    // Pass 4: populate the free lists, skipping the bitmap storage.
    const bitmap_end = bitmap_phys + bitmap_pages * PAGE_SIZE;
    i = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
        if (e.type != .usable) continue;

        var start = e.base;
        const end = e.base + e.length;

        if (start < bitmap_end and end > bitmap_phys) {
            // This region overlaps the bitmap: add whatever is on either side.
            if (start < bitmap_phys) addRange(start, bitmap_phys);
            start = bitmap_end;
            if (start >= end) continue;
        }
        addRange(start, end);
    }
}

// ── Reporting ────────────────────────────────────────────────────────────────

pub const Stats = struct {
    total_pages: usize,
    free_pages: usize,
    used_pages: usize,
    reserved_pages: usize,
};

pub fn stats() Stats {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);
    return .{
        .total_pages = total_pages,
        .free_pages = free_pages,
        .used_pages = total_pages - free_pages - reserved_pages,
        .reserved_pages = reserved_pages,
    };
}

/// Free blocks per order — useful for spotting fragmentation.
pub fn freeCounts() [ORDER_COUNT]usize {
    const state = spinlock.acquireIrqSave(&lock);
    defer spinlock.releaseIrqRestore(&lock, state);

    var counts: [ORDER_COUNT]usize = [_]usize{0} ** ORDER_COUNT;
    var order: usize = 0;
    while (order <= MAX_ORDER) : (order += 1) {
        var n: usize = 0;
        var node = free_lists[order];
        while (node) |x| : (node = x.next) n += 1;
        counts[order] = n;
    }
    return counts;
}

pub fn hhdmBase() u64 {
    return hhdm_offset;
}
