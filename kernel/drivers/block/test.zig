//! Block layer verification.
//!
//! Reads known markers off the disk, then does a write/read round trip on a
//! scratch sector well past anything a filesystem would use.

const std = @import("std");
const block = @import("block.zig");
const console = @import("../../console.zig");

/// Far enough out that no filesystem structure is at risk.
const SCRATCH_LBA: u64 = 2048;

pub fn run() void {
    const devs = block.list();
    if (devs.len == 0) {
        console.warn("block tests skipped: no devices", .{});
        return;
    }
    const dev = &devs[0];

    console.write("\n");
    console.info("block device tests on {s}:", .{dev.nameSlice()});

    var buf: [512]u8 align(8) = undefined;
    var passed: usize = 0;
    var failed: usize = 0;

    // Read LBA 0 and check the signature written into the image.
    if (dev.read(0, 1, &buf)) |_| {
        const ok = std.mem.startsWith(u8, &buf, "ORANGEOS-SECTOR-0");
        report("read LBA 0 returns the expected signature", ok, &passed, &failed);
        if (!ok) {
            console.print("         got: {s}\n", .{buf[0..24]});
        }
    } else |e| {
        console.print("  [FAIL] read LBA 0: {s}\n", .{@errorName(e)});
        failed += 1;
    }

    // A non-zero LBA proves the address is actually reaching the device.
    if (dev.read(100, 1, &buf)) |_| {
        const ok = std.mem.startsWith(u8, &buf, "HELLO-FROM-LBA-100");
        report("read LBA 100 returns its own distinct marker", ok, &passed, &failed);
    } else |e| {
        console.print("  [FAIL] read LBA 100: {s}\n", .{@errorName(e)});
        failed += 1;
    }

    // Write/read round trip.
    var out: [512]u8 align(8) = undefined;
    for (&out, 0..) |*b, i| b.* = @truncate(i *% 7 +% 13);

    if (dev.write(SCRATCH_LBA, 1, &out)) |_| {
        @memset(&buf, 0);
        if (dev.read(SCRATCH_LBA, 1, &buf)) |_| {
            report("write then read returns identical bytes", std.mem.eql(u8, &out, &buf), &passed, &failed);
        } else |e| {
            console.print("  [FAIL] read back: {s}\n", .{@errorName(e)});
            failed += 1;
        }
    } else |e| {
        console.print("  [FAIL] write: {s}\n", .{@errorName(e)});
        failed += 1;
    }

    // Multi-sector transfer, to exercise the PRDT byte count.
    var multi: [4096]u8 align(8) = undefined;
    for (&multi, 0..) |*b, i| b.* = @truncate(i *% 31 +% 5);
    var back: [4096]u8 align(8) = undefined;

    if (dev.write(SCRATCH_LBA + 8, 8, &multi)) |_| {
        @memset(&back, 0);
        if (dev.read(SCRATCH_LBA + 8, 8, &back)) |_| {
            report("8-sector transfer round trips intact", std.mem.eql(u8, &multi, &back), &passed, &failed);
        } else |e| {
            console.print("  [FAIL] multi read: {s}\n", .{@errorName(e)});
            failed += 1;
        }
    } else |e| {
        console.print("  [FAIL] multi write: {s}\n", .{@errorName(e)});
        failed += 1;
    }

    // Out-of-range access must be refused, not clamped.
    const bad = dev.read(dev.sectors + 1, 1, &buf);
    report("read past end of device is rejected", bad == block.Error.OutOfRange, &passed, &failed);

    console.print("\n[{s}] block: {d} passed, {d} failed\n", .{
        if (failed == 0) " ok " else "FAIL", passed, failed,
    });
}

fn report(name: []const u8, ok: bool, passed: *usize, failed: *usize) void {
    if (ok) {
        passed.* += 1;
        console.print("  [pass] {s}\n", .{name});
    } else {
        failed.* += 1;
        console.print("  [FAIL] {s}\n", .{name});
    }
}
