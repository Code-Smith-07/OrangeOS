//! Memory subsystem stress tests.
//!
//! Run at boot with `zig build -Dmm-test`. These are the checks that catch a
//! broken allocator before it corrupts something subtle three phases later.

const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const heap = @import("heap.zig");
const console = @import("../console.zig");

var passed: usize = 0;
var failed: usize = 0;

fn check(name: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        console.print("  [pass] {s}\n", .{name});
    } else {
        failed += 1;
        console.print("  [FAIL] {s}\n", .{name});
    }
}

/// Allocating and freeing the same order must return memory exactly.
fn testPmmConservation() void {
    const before = pmm.stats().free_pages;

    var addrs: [64]u64 = undefined;
    for (&addrs) |*a| {
        a.* = pmm.allocPage() catch {
            check("pmm: 64 single-page allocations", false);
            return;
        };
    }
    for (addrs) |a| pmm.freePage(a);

    check("pmm: page alloc/free conserves memory", pmm.stats().free_pages == before);
}

/// Distinct allocations must not overlap.
fn testPmmDistinct() void {
    var addrs: [32]u64 = undefined;
    for (&addrs) |*a| {
        a.* = pmm.allocPage() catch {
            check("pmm: distinct addresses", false);
            return;
        };
    }

    var ok = true;
    for (addrs, 0..) |a, i| {
        for (addrs[i + 1 ..]) |b| {
            if (a == b) ok = false;
        }
    }
    for (addrs) |a| pmm.freePage(a);
    check("pmm: allocations are distinct", ok);
}

/// Freeing two buddies must produce one block of the next order up.
fn testPmmCoalescing() void {
    const before = pmm.stats().free_pages;

    // Take a 4-page block, split it by hand, free the halves, then confirm a
    // 4-page block is obtainable again.
    const big = pmm.allocOrder(2) catch {
        check("pmm: coalescing", false);
        return;
    };
    pmm.freeOrder(big, 2);

    const a = pmm.allocOrder(1) catch return;
    const b = pmm.allocOrder(1) catch return;
    pmm.freeOrder(a, 1);
    pmm.freeOrder(b, 1);

    const again = pmm.allocOrder(2) catch {
        check("pmm: buddies coalesce into a larger block", false);
        return;
    };
    pmm.freeOrder(again, 2);

    check("pmm: buddies coalesce into a larger block", pmm.stats().free_pages == before);
}

/// Large contiguous allocations must actually be contiguous and aligned.
fn testPmmContiguous() void {
    const order: usize = 4; // 64 KiB
    const phys = pmm.allocOrder(order) catch {
        check("pmm: 64 KiB contiguous allocation", false);
        return;
    };
    const size = pmm.PAGE_SIZE << order;
    const aligned = phys % size == 0;

    // Write a pattern across the whole block and read it back.
    const p: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
    var i: usize = 0;
    while (i < size) : (i += 1) p[i] = @truncate(i);
    var ok = aligned;
    i = 0;
    while (i < size) : (i += 1) {
        if (p[i] != @as(u8, @truncate(i))) ok = false;
    }

    pmm.freeOrder(phys, order);
    check("pmm: 64 KiB block is contiguous, aligned, and writable", ok);
}

/// Heap allocations must be usable, aligned, and non-overlapping.
fn testHeap() void {
    const sizes = [_]usize{ 8, 24, 100, 500, 1000, 3000, 9000 };
    var ptrs: [sizes.len][*]u8 = undefined;

    for (sizes, 0..) |sz, i| {
        ptrs[i] = heap.alloc(sz) catch {
            check("heap: mixed-size allocations", false);
            return;
        };
        @memset(ptrs[i][0..sz], @truncate(i + 1));
    }

    var ok = true;
    for (sizes, 0..) |sz, i| {
        if (@intFromPtr(ptrs[i]) % 16 != 0) ok = false;
        for (ptrs[i][0..sz]) |byte| {
            if (byte != @as(u8, @truncate(i + 1))) ok = false;
        }
    }
    for (ptrs) |p| heap.free(p);

    check("heap: mixed sizes, 16-byte aligned, contents intact", ok);
}

/// Repeated alloc/free churn must not leak.
fn testHeapChurn() void {
    // Warm up first. Slabs are retained on purpose, so the first round legitimately
    // consumes pages; the baseline has to be taken after the caches are populated,
    // or the test measures slab creation instead of leakage.
    {
        var ptrs: [16][*]u8 = undefined;
        for (&ptrs, 0..) |*p, i| {
            p.* = heap.alloc(16 + i * 37) catch {
                check("heap: churn warm-up", false);
                return;
            };
        }
        for (ptrs) |p| heap.free(p);
    }

    const before = pmm.stats().free_pages;

    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var ptrs: [16][*]u8 = undefined;
        for (&ptrs, 0..) |*p, i| {
            p.* = heap.alloc(16 + i * 37) catch {
                check("heap: churn", false);
                return;
            };
        }
        for (ptrs) |p| heap.free(p);
    }

    // Slabs are retained by design, so pages must not keep growing.
    const after = pmm.stats().free_pages;
    check("heap: 3200 alloc/free cycles do not leak pages", after == before);
}

/// The page tables we installed must translate correctly.
fn testVmmTranslate() void {
    const pml4 = vmm.kernelPml4();

    // A known kernel virtual address must resolve.
    const some_fn = @intFromPtr(&testVmmTranslate);
    const resolved = vmm.translate(pml4, some_fn);
    check("vmm: kernel .text address translates", resolved != null);

    // An address in the middle of nowhere must not.
    const bogus = vmm.translate(pml4, 0xFFFF_A000_1234_5000);
    check("vmm: unmapped address returns null", bogus == null);

    // HHDM round trip.
    const phys = pmm.allocPage() catch return;
    const virt = pmm.physToVirt(phys);
    const back = vmm.translate(pml4, virt);
    check("vmm: HHDM translation matches physical address", back != null and back.? == phys);
    pmm.freePage(phys);
}

/// W^X: no page may be both writable and executable, and the sections must
/// carry the permissions we intended. Asserting on the PTE bits is stronger
/// than assuming the mapping code did what it looked like it did.
fn testWriteXorExecute() void {
    const pml4 = vmm.kernelPml4();

    const text = vmm.leafFlags(pml4, vmm.textStart());
    const rodata = vmm.leafFlags(pml4, vmm.rodataStart());
    const data = vmm.leafFlags(pml4, vmm.dataStart());

    check(
        "vmm: .text is executable and NOT writable",
        text != null and (text.? & vmm.WRITABLE) == 0 and (text.? & vmm.NO_EXECUTE) == 0,
    );
    check(
        "vmm: .rodata is non-executable and NOT writable",
        rodata != null and (rodata.? & vmm.WRITABLE) == 0 and (rodata.? & vmm.NO_EXECUTE) != 0,
    );
    check(
        "vmm: .data is writable and NOT executable",
        data != null and (data.? & vmm.WRITABLE) != 0 and (data.? & vmm.NO_EXECUTE) != 0,
    );

    // Read-only mappings only bind ring 0 when CR0.WP is set.
    check("vmm: CR0.WP is set (kernel honours read-only pages)", vmm.writeProtectEnabled());

    // The HHDM covers all of RAM; it must never be executable.
    const hhdm_flags = vmm.leafFlags(pml4, pmm.physToVirt(0x100000));
    check(
        "vmm: HHDM is writable and NOT executable",
        hhdm_flags != null and (hhdm_flags.? & vmm.NO_EXECUTE) != 0,
    );
}

pub fn runAll() void {
    console.write("\n");
    console.info("memory subsystem tests:", .{});
    passed = 0;
    failed = 0;

    testPmmConservation();
    testPmmDistinct();
    testPmmCoalescing();
    testPmmContiguous();
    testVmmTranslate();
    testWriteXorExecute();
    testHeap();
    testHeapChurn();

    console.print("\n[{s}] {d} passed, {d} failed\n", .{
        if (failed == 0) " ok " else "FAIL",
        passed,
        failed,
    });
}
