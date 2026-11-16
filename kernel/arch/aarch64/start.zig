//! Orange OS on Arm64, stage A0 (docs/design/015).
//!
//! This is the first piece of the Arm port: the kernel boots on an Arm
//! virtual machine (QEMU "virt"), reads the device tree, takes interrupts,
//! runs a 1000 Hz timer on every processor, starts the other processors
//! and shows a picture. It does not run programs yet: the memory manager,
//! scheduler and file system of the x86 kernel join in stage A1.
//!
//! Every line printed here is checked by tools/arm_boot_smoke.py.

const std = @import("std");
const cpu = @import("cpu.zig");
const exceptions = @import("exceptions.zig");
const fdt = @import("fdt.zig");
const gic = @import("gic.zig");
const display = @import("display.zig");
const gpu = @import("virtio_gpu.zig");
const timer = @import("timer.zig");
const uart = @import("uart.zig");

/// A boot loader passes the device tree's address; QEMU, loading the kernel
/// directly, passes nothing and puts the tree at the very start of memory.
const DEVICE_TREE_DEFAULT: u64 = 0x4000_0000;

/// In boot.S's section, which is linked at its physical address.
extern const _secondary_start: u8;
extern const __kernel_start: u8;
extern const __kernel_end: u8;

var online = std.atomic.Value(usize).init(1);
var have_interrupts = false;

pub fn panic(message: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    cpu.interruptsOff();
    uart.emergency("\nKERNEL PANIC (arm64): {s}\n", .{message});
    while (true) cpu.waitForInterrupt();
}

export fn kmain(processor: u64, device_tree: u64) callconv(.c) noreturn {
    cpu.setIndex(@intCast(processor));
    exceptions.install();
    if (processor != 0) secondary();

    uart.init(null);
    uart.print("\nOrange OS arm64: Zest kernel, stage A0\n", .{});

    const given = if (device_tree >= DEVICE_TREE_DEFAULT) fdt.Tree.at(cpu.ptr([*]const u8, device_tree)) else null;
    const tree = given orelse fdt.Tree.at(cpu.ptr([*]const u8, DEVICE_TREE_DEFAULT)) orelse {
        uart.print("arm64: no device tree was passed or found at the start of memory; cannot continue\n", .{});
        halt();
    };
    if (tree.find("arm,pl011")) |node| uart.init(node.address());

    const memory = tree.findType("memory");
    const memory_bytes = if (memory) |m| m.size() orelse 0 else 0;
    const processors = @min(tree.count("cpu"), cpu.MAX_CPUS);
    const midr = cpu.read("midr_el1");
    uart.print("arm64: {d} MB of memory, {d} processors, maker 0x{x} part 0x{x}\n", .{
        memory_bytes / (1024 * 1024), processors, midr >> 24, (midr >> 4) & 0xFFF,
    });
    uart.print("arm64: kernel occupies {d} KB, counter runs at {d} Hz\n", .{
        (@intFromPtr(&__kernel_end) - @intFromPtr(&__kernel_start)) / 1024, cpu.counterHz(),
    });

    // 1. A synchronous exception is taken and returned from.
    asm volatile ("svc #0x4F53");
    asm volatile ("svc #0x4F53");
    uart.print("arm64: exceptions {s}\n", .{if (exceptions.self_test_calls == 2) "ok" else "FAILED"});

    // 2. Interrupts and the timer.
    if (tree.find("arm,gic-v3")) |node| {
        gic.init(node.addressAt(0).?, node.addressAt(1).?);
        have_interrupts = gic.initProcessor();
    }
    if (!have_interrupts) {
        uart.print("arm64: no GICv3 interrupt controller (start QEMU with gic-version=3)\n", .{});
        halt();
    }
    timer.start();
    cpu.interruptsOn();
    const before = timer.ticksOn(0);
    cpu.spinMicros(200_000);
    const counted = timer.ticksOn(0) - before;
    uart.print("arm64: timer {d} ticks in 200 ms from {d} interrupts ({s})\n", .{
        counted, timer.interruptsOn(0), if (counted >= 198 and counted <= 202) "ok" else "FAILED",
    });

    // 3. The other processors.
    if (tree.find("arm,psci-0.2") orelse tree.find("arm,psci-1.0")) |psci| {
        cpu.conduit = if (std.mem.eql(u8, psci.method, "smc")) .smc else .hvc;
    }
    var started: usize = 1;
    var it = tree.nodes();
    while (it.next()) |node| {
        if (!std.mem.eql(u8, node.device_type, "cpu")) continue;
        const target = node.address() orelse continue;
        if (target == cpu.affinity() or started >= cpu.MAX_CPUS) continue;
        const result = cpu.startProcessor(target, @intFromPtr(&_secondary_start), started);
        if (result != 0) {
            uart.print("arm64: processor 0x{x} refused to start ({d})\n", .{ target, result });
            continue;
        }
        // One at a time: each must report before the next is started.
        const wait = cpu.counter();
        while (online.load(.acquire) <= started and cpu.elapsedMicros(wait) < 2_000_000) cpu.relax();
        started += 1;
    }
    cpu.spinMicros(100_000);
    var ticking: usize = 0;
    for (0..processors) |n| {
        if (timer.ticksOn(n) >= 50) ticking += 1;
    }
    uart.print("arm64: {d} of {d} processors online, {d} taking timer ticks ({s})\n", .{
        online.load(.acquire),                                                                 processors, ticking,
        if (online.load(.acquire) == processors and ticking == processors) "ok" else "FAILED",
    });

    // 4. The screen: find the virtual GPU among the virtio devices.
    var shown = false;
    it = tree.nodes();
    while (it.next()) |node| {
        if (!node.is("virtio,mmio")) continue;
        const address = node.address() orelse continue;
        if (!gpu.probe(address)) continue;
        shown = display.init(address);
        break;
    }
    if (shown) {
        const frames = 30;
        const start = cpu.counter();
        for (0..frames) |_| {
            display.splash("Stage A0: boot, interrupts, timer, all processors");
            shown = display.present() and shown;
        }
        const micros = @max(cpu.elapsedMicros(start), 1);
        uart.print("arm64: display {d}x{d}, {d} full frames drawn and shown in {d} ms ({d} a second), {d} pixels drawn ({s})\n", .{
            display.WIDTH,               display.HEIGHT,        frames,                        micros / 1000,
            frames * 1_000_000 / micros, display.drawnPixels(), if (shown) "ok" else "FAILED",
        });
    } else {
        uart.print("arm64: no display (start QEMU with -device virtio-gpu-device -global virtio-mmio.force-legacy=false)\n", .{});
    }

    // 5. How fast is this machine? The same work as the feasibility test.
    const start = cpu.counter();
    const primes = sieveWork();
    uart.print("arm64: speed test counted {d} primes in {d} ms\n", .{ primes, cpu.elapsedMicros(start) / 1000 });

    uart.print("Orange OS arm64: stage A0 complete\n", .{});
    halt();
}

fn secondary() noreturn {
    if (gic.initProcessor()) {
        timer.start();
        cpu.interruptsOn();
    }
    uart.print("arm64: processor {d} online (hardware number 0x{x})\n", .{ cpu.index(), cpu.affinity() });
    _ = online.fetchAdd(1, .release);
    halt();
}

fn halt() noreturn {
    while (true) cpu.waitForInterrupt();
}

var sieve: [2_000_000]u8 = undefined;

/// Primes below two million, twenty times: memory writes and branches.
fn sieveWork() u64 {
    var total: u64 = 0;
    for (0..20) |_| {
        @memset(&sieve, 1);
        var i: usize = 2;
        while (i * i < sieve.len) : (i += 1) {
            if (sieve[i] == 0) continue;
            var j = i * i;
            while (j < sieve.len) : (j += i) sieve[j] = 0;
        }
        var count: u64 = 0;
        for (sieve[2..]) |s| count += s;
        total += count;
    }
    return total / 20;
}
