//! Orange OS — Zest kernel entry point on Arm64 (docs/design/015).
//!
//! boot.S starts every processor here. The first one brings the machine up
//! in the same order as the x86 kernel (main.zig) and with the same shared
//! code: memory, interrupts and time, the other processors, the disk, the
//! scheduler, then PID 1. What differs is only what is under kernel/arch.

const std = @import("std");
const build_options = @import("build_options");
const arch = @import("arch/arch.zig");
const cpu = @import("arch/aarch64/cpu.zig");
const fdt = @import("arch/aarch64/fdt.zig");
const gic = @import("arch/aarch64/gic.zig");
const uart = @import("arch/aarch64/uart.zig");
const display = @import("arch/aarch64/display.zig");
const virtio_gpu = @import("arch/aarch64/virtio_gpu.zig");
const bootinfo = arch.boot;
const console = @import("console.zig");
const fmt = @import("lib/fmt.zig");
const mm = @import("mm/mm.zig");
const mm_test = @import("mm/test.zig");
const tlb = @import("mm/tlb.zig");
const tlb_test = @import("mm/tlb_test.zig");
const time = @import("time/time.zig");
const sched = @import("sched/sched.zig");
const sched_test = @import("sched/test.zig");
const process = @import("sched/process.zig");
const block = @import("drivers/block/block.zig");
const ramdisk = @import("drivers/block/ramdisk.zig");
const partition = @import("drivers/block/partition.zig");
const vfs = @import("fs/vfs/vfs.zig");
const panic_mod = @import("panic.zig");

pub const panic = panic_mod.handler;

const VERSION = "0.1.0";
/// A boot loader passes the device tree's address; QEMU, loading the kernel
/// directly, passes nothing and puts the tree at the very start of memory.
const DEVICE_TREE_DEFAULT: u64 = 0x4000_0000;

export fn kmain(processor: u64, device_tree: u64) callconv(.c) noreturn {
    if (processor != 0) arch.smp.apEntry(@intCast(processor));

    // ── 1. Serial first, at the address every "virt" machine uses. ───────
    _ = arch.serial.init();
    arch.percpu.init();
    arch.isr.install();
    arch.tsc.calibrate();
    arch.serial.write("\nOrange OS v" ++ VERSION ++ " - Zest kernel booting (arm64)...\n");

    // ── 2. The device tree: memory, processors, where the devices are. ───
    const given = if (device_tree >= DEVICE_TREE_DEFAULT) fdt.Tree.at(cpu.ptr([*]const u8, device_tree)) else null;
    const tree = given orelse fdt.Tree.at(cpu.ptr([*]const u8, DEVICE_TREE_DEFAULT)) orelse {
        arch.serial.write("[FAIL] no device tree was passed or found at the start of memory\n");
        arch.io.hang();
    };
    if (!bootinfo.init(&tree)) {
        arch.serial.write("[FAIL] the device tree describes no memory\n");
        arch.io.hang();
    }
    uart.init(bootinfo.uart);
    console.write("\n");
    console.ok("serial console up (PL011)", .{});
    const midr = cpu.read("midr_el1");
    console.print("[info] arm64: {d} MB of memory, {d} processors, maker 0x{x} part 0x{x}, counter {d} Hz\n", .{
        bootinfo.memory_bytes / (1024 * 1024), bootinfo.cpu_count, midr >> 24, (midr >> 4) & 0xFFF, cpu.counterHz(),
    });

    // ── 3. Memory. pmm -> vmm -> heap, the shared code. ──────────────────
    mm.init() catch |e| {
        console.err("memory init failed: {s}", .{@errorName(e)});
        arch.io.hang();
    };
    mm.reportFragmentation();
    if (build_options.mm_test) mm_test.runAll();

    // ── 4. Interrupts, the tick, the other processors. ───────────────────
    const distributor = bootinfo.gic_distributor orelse fail("no GICv3 interrupt controller (start QEMU with gic-version=3)");
    const redistributors = bootinfo.gic_redistributors orelse fail("the interrupt controller has no redistributors");
    gic.init(distributor, redistributors);
    if (!gic.initProcessor()) fail("this processor has no interrupt controller interface");
    console.ok("GICv3 interrupt controller online", .{});
    time.init();
    arch.io.sti();
    console.ok("interrupts enabled - system is preemptible", .{});
    arch.serial.enableInput();
    console.ok("serial input enabled (PL011 receive interrupt)", .{});
    tlb.init();
    {
        const random = @import("lib/random.zig");
        const wall = time.unixNanos() orelse 0;
        const stats = @import("mm/pmm.zig").stats();
        random.init(std.mem.asBytes(&[_]u64{ wall, stats.free_pages, stats.total_pages, cpu.counter() }));
        console.ok("random: entropy from {s}{s}", .{ random.sourceName(), if (random.isReady()) ", ready" else ", gathering" });
    }
    arch.smp.installPanicHalt();
    arch.smp.init() catch |e| console.warn("SMP bring-up failed: {s}", .{@errorName(e)});

    // ── 5. The screen: the boot picture through the virtual GPU. ─────────
    showSplash();

    // ── 6. The disk. ─────────────────────────────────────────────────────
    mountDisk();

    // ── 7. Scheduler. From here the kernel runs as threads. ──────────────
    sched.init() catch |e| {
        console.err("scheduler init failed: {s}", .{@errorName(e)});
        arch.io.hang();
    };
    console.ok("scheduler: MLFQ, 4 levels, idle thread created", .{});

    if (build_options.sched_test) sched_test.spawnAll();
    if (build_options.runtime_test) {
        _ = sched.spawn("tlb-probe", tlb_test.run, null, .normal) catch {};
    }
    @import("fs/tmpfs/persist.zig").startService();
    _ = sched.spawn("orphan-reaper", sched.orphanReaper, null, .batch) catch |e| {
        console.err("could not spawn orphan reaper: {s}", .{@errorName(e)});
        arch.io.hang();
    };
    _ = sched.spawn("cpu-report", cpuReport, null, .batch) catch {};
    if (!build_options.runtime_test) _ = process.spawnInit() catch |e| {
        console.err("could not spawn init: {s}", .{@errorName(e)});
    };

    console.ok("arm64 kernel ready - handing over to the scheduler", .{});
    tlb.enable();
    arch.smp.releaseAps();
    sched.start();
}

fn fail(comptime message: []const u8) noreturn {
    console.err(message, .{});
    arch.io.hang();
}

fn showSplash() void {
    const base = bootinfo.virtio_base orelse return;
    for (0..bootinfo.virtio_count) |n| {
        const address = base + n * 0x200;
        if (!virtio_gpu.probe(address)) continue;
        if (!display.init(address)) break;
        display.splash("Arm64: shared kernel, programs from disk");
        if (display.present()) console.print("[ ok ] display: {d}x{d} through virtio-gpu\n", .{ display.WIDTH, display.HEIGHT });
        return;
    }
    console.info("no display (start QEMU with -device virtio-gpu-device)", .{});
}

fn mountDisk() void {
    if (bootinfo.ramdisk.size == 0) {
        console.warn("no disk: start QEMU with a ramdisk (scripts/run-arm.sh does)", .{});
        return;
    }
    const disk = ramdisk.init(cpu.virt(bootinfo.ramdisk.base), bootinfo.ramdisk.size) orelse return;
    var cap: [32]u8 = undefined;
    console.print("[ ok ] block: {s} - {s} in memory ({d} sectors)\n", .{ disk.nameSlice(), fmt.humanBytes(&cap, disk.byteCapacity()), disk.sectors });
    if (partition.scanAll() == 0) console.info("no GPT partitions found", .{});
    for (block.list()) |*d| {
        if (d.lba_offset == 0) continue; // partitions, not whole disks
        vfs.mountRoot(d) catch continue;
        const sb = vfs.superblock();
        console.print("[ ok ] mounted CitrusFS on {s}: {s}, {d} inodes\n", .{
            d.nameSlice(), fmt.humanBytes(&cap, sb.total_blocks * sb.block_size), sb.inode_count,
        });
        @import("fs/tmpfs/persist.zig").mount();
        return;
    }
    console.warn("no CitrusFS partition found - / not mounted", .{});
}

/// Wait a while, then report how much work each core has done.
fn cpuReport(_: ?*anyopaque) void {
    sched.sleepMs(12_000);
    sched.reportCpus(arch.smp.cpusOnline());
}
