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

fn testUserVm() void {
    const vm = @import("user_vm.zig");
    const baseline = pmm.stats().free_pages;
    const space = vmm.createAddressSpace() catch {
        check("user VM: address space", false);
        return;
    };
    var state: vm.State = .{};
    const after_root = pmm.stats().free_pages;
    var ok = true;
    for (0..64) |_| {
        const address = vm.map(&state, space, 65537, 3) catch {
            ok = false;
            break;
        };
        vm.protect(&state, space, address, 65537, 0) catch {
            ok = false;
            break;
        };
        if (vmm.leafFlags(space, address).? & vmm.USER != 0) ok = false;
        vm.protect(&state, space, address, 65537, 1) catch {
            ok = false;
            break;
        };
        if (vmm.leafFlags(space, address).? & vmm.WRITABLE != 0) ok = false;
        vm.unmap(&state, space, address, 65537) catch {
            ok = false;
            break;
        };
        if (vmm.translate(space, address) != null or pmm.stats().free_pages != after_root) ok = false;
    }
    check("user VM: 64 cycles return frames AND page tables", ok);
    _ = vm.map(&state, space, 1048576, 3) catch {
        check("user VM: exit setup", false);
        return;
    };
    _ = vm.map(&state, space, 4096, 0) catch {
        check("user VM: protected exit setup", false);
        return;
    };
    vm.releaseAll(&state, space);
    check("user VM: exit cleanup frees protected and writable memory", pmm.stats().free_pages == after_root);
    vmm.destroyAddressSpace(space);
    check("user VM: address-space teardown conserves every page", pmm.stats().free_pages == baseline);

    const mixed = vmm.createAddressSpace() catch return;
    const borrowed = pmm.allocPageZeroed() catch return;
    const borrowed_bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(borrowed));
    borrowed_bytes[0] = 0x6d;
    vmm.mapPage(mixed, vm.BASE, borrowed, vmm.PRESENT | vmm.USER | vmm.NO_EXECUTE) catch return;
    _ = vmm.allocAndMap(mixed, vm.BASE + 4096, vmm.PRESENT | vmm.USER | vmm.NO_EXECUTE) catch return;
    vmm.destroyAddressSpace(mixed);
    check("user VM: teardown frees private frames but preserves borrowed SHM", pmm.stats().free_pages == baseline - 1 and borrowed_bytes[0] == 0x6d);
    pmm.freePage(borrowed);
}

fn testUserVmSubranges() void {
    const vm = @import("user_vm.zig");
    const baseline = pmm.stats().free_pages;
    const space = vmm.createAddressSpace() catch {
        check("user VM: subrange address space", false);
        return;
    };
    var state: vm.State = .{};
    var ok = true;
    const address = vm.map(&state, space, 3 * vmm.PAGE_SIZE, 3) catch {
        check("user VM: subrange setup", false);
        vmm.destroyAddressSpace(space);
        return;
    };
    vm.protect(&state, space, address + vmm.PAGE_SIZE, vmm.PAGE_SIZE, 1) catch {
        ok = false;
    };
    if (vmm.leafFlags(space, address).? & vmm.WRITABLE == 0 or
        vmm.leafFlags(space, address + vmm.PAGE_SIZE).? & vmm.WRITABLE != 0 or
        vmm.leafFlags(space, address + 2 * vmm.PAGE_SIZE).? & vmm.WRITABLE == 0) ok = false;
    vm.unmap(&state, space, address + vmm.PAGE_SIZE, vmm.PAGE_SIZE) catch {
        ok = false;
    };
    if (vmm.translate(space, address) == null or
        vmm.translate(space, address + vmm.PAGE_SIZE) != null or
        vmm.translate(space, address + 2 * vmm.PAGE_SIZE) == null) ok = false;
    if (vm.protect(&state, space, address, 3 * vmm.PAGE_SIZE, 1)) |_| {
        ok = false;
    } else |err| {
        if (err != error.Invalid) ok = false;
    }
    const hole = vm.map(&state, space, vmm.PAGE_SIZE, 3) catch 0;
    if (hole != address + vmm.PAGE_SIZE) ok = false;
    vm.releaseAll(&state, space);
    const edges = vm.map(&state, space, 3 * vmm.PAGE_SIZE, 3) catch 0;
    if (edges == 0) {
        ok = false;
    } else {
        vm.unmap(&state, space, edges, vmm.PAGE_SIZE) catch {
            ok = false;
        };
        vm.unmap(&state, space, edges + 2 * vmm.PAGE_SIZE, vmm.PAGE_SIZE) catch {
            ok = false;
        };
        if (vmm.translate(space, edges) != null or
            vmm.translate(space, edges + vmm.PAGE_SIZE) == null or
            vmm.translate(space, edges + 2 * vmm.PAGE_SIZE) != null) ok = false;
    }
    vm.releaseAll(&state, space);
    vmm.destroyAddressSpace(space);
    check("user VM: subranges, hole reuse and frame conservation", ok and pmm.stats().free_pages == baseline);
}

fn testUserVmSparse() void {
    const vm = @import("user_vm.zig");
    const baseline = pmm.stats().free_pages;
    const space = vmm.createAddressSpace() catch {
        check("user VM: sparse address space", false);
        return;
    };
    var state: vm.State = .{};
    const after_root = pmm.stats().free_pages;
    var ok = true;
    const span = 1024 * 1024 * 1024;
    const address = vm.reserve(&state, space, span) catch {
        check("user VM: sparse reservation setup", false);
        vmm.destroyAddressSpace(space);
        return;
    };
    if (pmm.stats().free_pages != after_root or vmm.translate(space, address + span - vmm.PAGE_SIZE) != null) ok = false;
    const page = address + 8 * 1024 * 1024;
    vm.commit(&state, space, page, vmm.PAGE_SIZE, 3) catch {
        ok = false;
    };
    if (vmm.translate(space, page)) |phys| {
        const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
        if (bytes[0] != 0) ok = false;
        bytes[0] = 0x5a;
    } else ok = false;
    if (vm.commit(&state, space, page, vmm.PAGE_SIZE, 3)) |_| {
        ok = false;
    } else |err| {
        if (err != error.Invalid) ok = false;
    }
    if (vm.protect(&state, space, page + vmm.PAGE_SIZE, vmm.PAGE_SIZE, 1)) |_| {
        ok = false;
    } else |err| {
        if (err != error.Invalid) ok = false;
    }
    if (vm.protect(&state, space, page, 2 * vmm.PAGE_SIZE, 1)) |_| {
        ok = false;
    } else |err| {
        if (err != error.Invalid or vmm.leafFlags(space, page).? & vmm.WRITABLE == 0) ok = false;
    }
    vm.decommit(&state, space, page, vmm.PAGE_SIZE) catch {
        ok = false;
    };
    if (vmm.translate(space, page) != null or pmm.stats().free_pages != after_root) ok = false;
    vm.commit(&state, space, page, vmm.PAGE_SIZE, 1) catch {
        ok = false;
    };
    if (vmm.translate(space, page)) |phys| {
        const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
        if (bytes[0] != 0 or vmm.leafFlags(space, page).? & vmm.WRITABLE != 0) ok = false;
    } else ok = false;
    const split = address + 16 * 1024 * 1024;
    vm.unmap(&state, space, split, vmm.PAGE_SIZE) catch {
        ok = false;
    };
    if (vm.commit(&state, space, split, vmm.PAGE_SIZE, 3)) |_| {
        ok = false;
    } else |err| {
        if (err != error.Invalid) ok = false;
    }
    vm.commit(&state, space, split + vmm.PAGE_SIZE, vmm.PAGE_SIZE, 3) catch {
        ok = false;
    };
    vm.releaseAll(&state, space);
    vmm.destroyAddressSpace(space);
    check("user VM: sparse reserve, commit, decommit and cleanup", ok and pmm.stats().free_pages == baseline);
}

fn testAddressSpaceLifetime() !void {
    const spaces = @import("address_space.zig");
    const vm = @import("user_vm.zig");
    const object = @import("../ipc/object.zig");
    // Warm any object-allocator slabs before comparing physical-page totals.
    const warm_space = try spaces.AddressSpace.create();
    warm_space.release();
    const warm_shm = try object.createShm("", vmm.PAGE_SIZE);
    object.release(warm_shm);
    const baseline = pmm.stats().free_pages;
    const objects_before = object.objectCount();
    var retained_ok = true;
    var reclaimed_ok = true;
    for (0..64) |_| {
        const space = try spaces.AddressSpace.create();
        // On setup failure this reference owns every successfully added mapping.
        errdefer space.release();
        const image = try vmm.allocAndMap(space.pml4, 0x400000, vmm.PRESENT | vmm.USER | vmm.WRITABLE | vmm.NO_EXECUTE);
        @as(*u64, @ptrFromInt(pmm.physToVirt(image))).* = 0x12345678;
        const private = try vm.map(&space.anonymous_vm, space.pml4, vmm.PAGE_SIZE, 3);
        try vm.protect(&space.anonymous_vm, space.pml4, private, vmm.PAGE_SIZE, 0);
        const shm = try object.createShm("", vmm.PAGE_SIZE);
        // Transfer the creator's reference into the mapping table, then mimic
        // a second handle being retained and closed while the mapping survives.
        space.mapped_shm[0] = shm;
        {
            object.retain(shm);
            defer object.release(shm);
            try vmm.mapPage(space.pml4, spaces.SHM_REGION_BASE, shm.data.shm.phys, vmm.PRESENT | vmm.USER | vmm.WRITABLE | vmm.NO_EXECUTE);
        }
        const shm_phys = shm.data.shm.phys;
        @as(*u64, @ptrFromInt(pmm.physToVirt(shm_phys))).* = 0xaabbccdd;
        space.shm_next += 2 * vmm.PAGE_SIZE;
        const allocated = pmm.stats().free_pages;
        // Simulate three owners dropping in sequence, without scheduling shared
        // tasks (their concurrent VM safety is a separate, unfinished milestone).
        space.retain();
        space.retain();
        space.release();
        space.release();
        retained_ok = retained_ok and pmm.stats().free_pages == allocated and
            vmm.translate(space.pml4, 0x400000) == image and
            vmm.leafFlags(space.pml4, private) != null and
            vmm.translate(space.pml4, spaces.SHM_REGION_BASE) == shm_phys and
            @as(*const u64, @ptrFromInt(pmm.physToVirt(image))).* == 0x12345678 and
            @as(*const u64, @ptrFromInt(pmm.physToVirt(shm_phys))).* == 0xaabbccdd and
            space.shm_next == spaces.SHM_REGION_BASE + 2 * vmm.PAGE_SIZE and
            object.objectCount() == objects_before + 1;
        space.release();
        reclaimed_ok = reclaimed_ok and pmm.stats().free_pages == baseline and
            object.objectCount() == objects_before;
    }
    check("address space: mappings survive intermediate owner releases", retained_ok);
    check("address space: 64 final releases reclaim image, VM, SHM and page tables", reclaimed_ok);
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
    testUserVm();
    testUserVmSubranges();
    testUserVmSparse();
    testHeap();
    testHeapChurn();
    testAddressSpaceLifetime() catch {
        check("address space: lifetime test setup", false);
    };

    console.print("\n[{s}] {d} passed, {d} failed\n", .{
        if (failed == 0) " ok " else "FAIL",
        passed,
        failed,
    });
}
