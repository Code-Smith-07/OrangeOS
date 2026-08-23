//! Memory management subsystem entry point.
//!
//! Bring-up order matters and is not negotiable:
//!   1. pmm  — page frames, seeded from the Limine memory map
//!   2. vmm  — our own page tables, built using pmm, then CR3 switched
//!   3. heap — slab caches, built on top of both

const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const heap = @import("heap.zig");
const console = @import("../console.zig");
const fmt = @import("../lib/fmt.zig");

pub const PAGE_SIZE = pmm.PAGE_SIZE;

pub fn init() !void {
    try pmm.init();
    const s = pmm.stats();
    var b1: [32]u8 = undefined;
    console.print("[ ok ] pmm: buddy allocator, {s} free across {d} pages\n", .{
        fmt.humanBytes(&b1, s.free_pages * PAGE_SIZE),
        s.free_pages,
    });

    try vmm.init();
    console.ok("vmm: kernel page tables built, CR3 switched", .{});

    heap.init();
    console.ok("heap: slab caches online (16 B - 2 KiB), kalloc ready", .{});
}

/// Free blocks per buddy order — a fragmentation snapshot.
pub fn reportFragmentation() void {
    const counts = pmm.freeCounts();
    console.write("[info] buddy free lists: ");
    var order: usize = 0;
    while (order < counts.len) : (order += 1) {
        if (counts[order] == 0) continue;
        const kib = (PAGE_SIZE << @intCast(order)) / 1024;
        console.print("{d}K x{d}  ", .{ kib, counts[order] });
    }
    console.write("\n");
}
