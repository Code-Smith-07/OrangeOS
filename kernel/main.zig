//! Orange OS — Zest kernel entry point.
//!
//! Phase 0: reach long mode via Limine, bring up serial, claim the
//! framebuffer, and report what the bootloader handed us.

const build_options = @import("build_options");
const limine = @import("boot/limine_req.zig");
const serial = @import("drivers/char/serial.zig");
const framebuffer = @import("drivers/video/framebuffer.zig");
const fbcon = @import("drivers/video/fbcon.zig");
const console = @import("console.zig");
const io = @import("arch/x86_64/io.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const mm = @import("mm/mm.zig");
const mm_test = @import("mm/test.zig");
const platform = @import("dev/acpi/init.zig");
const time = @import("time/time.zig");
const tsc = @import("time/tsc.zig");
const sched = @import("sched/sched.zig");
const smp = @import("arch/x86_64/smp.zig");
const net = @import("net/net.zig");
const sched_test = @import("sched/test.zig");
const process = @import("sched/process.zig");
const blk_test = @import("drivers/block/test.zig");
const fs_test = @import("fs/test.zig");
const percpu = @import("arch/x86_64/percpu.zig");
const syscall_entry = @import("arch/x86_64/syscall_entry.zig");
const fmt = @import("lib/fmt.zig");
const panic_mod = @import("panic.zig");

pub const panic = panic_mod.handler;

const VERSION = "0.1.0";

/// Called by Limine with interrupts disabled, on a bootloader-provided stack,
/// already in 64-bit long mode with the kernel mapped higher-half.
export fn kmain() callconv(.c) noreturn {
    // ── 1. Serial first. Everything after this is debuggable. ────────────────
    const have_serial = serial.init();
    serial.write("\n");
    serial.write("Orange OS v" ++ VERSION ++ " - Zest kernel booting...\n");

    // ── 2. Verify the bootloader honored our protocol revision. ──────────────
    if (!limine.baseRevisionSupported()) {
        serial.write("[FAIL] Limine base revision 3 not supported by this bootloader\n");
        io.hang();
    }

    // ── 3. Framebuffer + console. First pixels on screen. ────────────────────
    const have_fb = framebuffer.init() != null and fbcon.init();

    if (have_fb) drawBanner();

    console.write("\n");
    console.ok("serial console up (COM1, 115200 8N1)", .{});
    if (!have_serial) console.warn("serial loopback test failed", .{});

    // ── 4. Report what Limine gave us. ───────────────────────────────────────
    if (limine.bootloaderInfo()) |bi| {
        console.print("[info] bootloader: {s} {s}\n", .{ bi.name, bi.version });
    }

    if (framebuffer.get()) |f| {
        console.print("[ ok ] framebuffer: {d}x{d}, {d}bpp, pitch {d}\n", .{
            f.width, f.height, f.bpp, f.pitch,
        });
        const d = fbcon.dimensions();
        console.print("[ ok ] console: {d}x{d} cells\n", .{ d.cols, d.rows });
    } else {
        console.warn("no usable framebuffer - serial only", .{});
    }

    if (limine.hhdmOffset()) |off| {
        console.print("[info] HHDM offset: 0x{x:0>16}\n", .{off});
    }

    reportMemory();

    // ── 5. CPU structures. Faults become diagnosable from here on. ───────────
    gdt.init();
    console.ok("GDT + TSS installed (IST stacks for #DF, NMI, #MC)", .{});

    idt.init();
    console.ok("IDT installed (256 vectors, 32 exception handlers)", .{});

    // Per-CPU data must exist before interrupts are enabled. The timer handler
    // reads this core's index out of GS to decide whether it owns the wall
    // clock, and a GS_BASE of zero makes that a null dereference at the first
    // tick - which is exactly what happened.
    percpu.init();
    console.ok("per-CPU block established (GS_BASE)", .{});

    // ── 6. Memory. pmm -> vmm -> heap, in that order. ───────────────────────
    mm.init() catch |e| {
        console.err("memory init failed: {s}", .{@errorName(e)});
        io.hang();
    };
    mm.reportFragmentation();

    if (build_options.mm_test) mm_test.runAll();

    // ── 7. Platform: ACPI, APICs, timers, interrupts on. ────────────────────
    console.write("\n");
    platform.init() catch |e| {
        console.err("platform init failed: {s}", .{@errorName(e)});
        io.hang();
    };

    // ── 8. Scheduler. From here the kernel runs as threads. ─────────────────
    sched.init() catch |e| {
        console.err("scheduler init failed: {s}", .{@errorName(e)});
        io.hang();
    };
    console.ok("scheduler: MLFQ, 4 levels, idle thread created", .{});

    // ── 9. Syscall gate and per-CPU data, needed before any ring 3 code. ────
    syscall_entry.init();
    console.ok("syscall gate armed (SYSCALL/SYSRET)", .{});

    console.write("\n");
    console.ok("Phase 5 complete - Zest reads and runs from disk.", .{});
    console.info("next: Pulp libc, IPC, Seed, Juice shell (Phase 6)", .{});

    if (build_options.blk_test) blk_test.run();
    if (build_options.fs_test) fs_test.run();

    if (build_options.sched_test) sched_test.spawnAll();

    // A short-lived reporter, so the per-CPU switch counts are visible without
    // needing a userland tool for it.
    _ = sched.spawn("cpu-report", cpuReport, null, .batch) catch {};
    _ = sched.spawn("net-test", netTest, null, .normal) catch {};
    _ = sched.spawn("init", process.initThread, null, .normal) catch |e| {
        console.err("could not spawn init: {s}", .{@errorName(e)});
    };

    // Let the other cores into the scheduler now that the run queues exist
    // and there is work on them.
    smp.releaseAps();

    // Hand the boot context to the scheduler. This never returns: the boot
    // stack is abandoned and every subsequent instruction runs on a thread.
    sched.start();

    // A deliberate breakpoint proves the IDT actually routes and returns.
    selfTest();

    if (build_options.fault_test) faultTest();

    io.hang();
}

/// Resolve the gateway and ping it. Proves the whole path: descriptor rings,
/// ARP, IPv4 header construction, checksums, and the receive dispatch.
fn netTest(_: ?*anyopaque) void {
    if (!net.isUp()) return;
    time.busySleepMs(3000);

    const gw = net.gateway();
    console.write("\n");
    console.info("network self-test: pinging the gateway...", .{});

    if (net.resolve(gw, 2000)) |mac| {
        console.print("[ ok ] arp {d}.{d}.{d}.{d} is {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            gw[0], gw[1], gw[2], gw[3], mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
        });
    } else {
        console.err("arp: no reply from the gateway", .{});
        return;
    }

    var seq: u16 = 1;
    var replies: u32 = 0;
    while (seq <= 4) : (seq += 1) {
        if (net.ping(gw, seq, 1000)) |us| {
            replies += 1;
            console.print("[ ok ] reply from {d}.{d}.{d}.{d}: seq={d} time={d}.{d} ms\n", .{
                gw[0], gw[1], gw[2], gw[3], seq, us / 1000, (us % 1000) / 100,
            });
        } else {
            console.warn("ping seq={d} timed out", .{seq});
        }
        time.busySleepMs(400);
    }

    console.print("[{s}] network: {d}/4 replies\n", .{
        if (replies == 4) " ok " else "warn", replies,
    });
}

/// Wait a while, then report how much work each core has done.
fn cpuReport(_: ?*anyopaque) void {
    time.busySleepMs(12_000);
    sched.reportCpus(smp.cpusOnline());
}

/// Prove the timer actually fires: sample the tick counter across a known
/// interval and confirm it advanced by roughly the right amount.
fn heartbeat() void {
    console.write("\n");
    console.info("timer self-test: measuring against the TSC...", .{});

    // Sleep on the TSC, then ask how many ticks actually arrived. On real
    // hardware this matches TICK_HZ; under TCG emulation it shows how many
    // the machine could not service.
    const measured = time.measuredTickHz();

    console.print("[info] tick rate: {d} Hz nominal, {d} Hz observed\n", .{
        time.TICK_HZ, measured,
    });

    const nominal: u64 = time.TICK_HZ;
    const drift = if (measured > nominal) measured - nominal else nominal - measured;
    const pct = if (nominal == 0) 100 else drift * 100 / nominal;

    if (pct <= 5) {
        console.ok("timer within 5% of nominal", .{});
    } else {
        console.warn("dropping {d}% of ticks - expected under TCG emulation", .{pct});
        console.info("timekeeping is TSC-based, so uptime stays correct", .{});
    }

    // Independent check: does one TSC-measured second really take one second?
    const t0 = time.monotonicNs();
    time.busySleepMs(1000);
    const dt_ms = (time.monotonicNs() - t0) / 1_000_000;
    console.print("[ ok ] 1000 ms sleep measured {d} ms\n", .{dt_ms});

    console.write("\n");
    console.info("idle: system is alive and preemptible", .{});

    var last_second: u64 = 0;
    while (true) {
        asm volatile ("hlt");
        const secs = time.millisSinceBoot() / 1000;
        if (secs != last_second) {
            last_second = secs;
            if (secs % 5 == 0) {
                console.print("[info] uptime {d}s, {d} ticks\n", .{ secs, time.tickCount() });
            }
        }
    }
}

/// Deliberately fault, three calls deep, so the panic path and the frame-pointer
/// backtrace both get exercised. Enabled with `zig build -Dfault-test`.
fn faultTest() void {
    console.write("\n");
    console.info("fault test: dereferencing null from nested calls...", .{});
    faultLevel1();
}

noinline fn faultLevel3() void {
    const bad: *allowzero volatile u64 = @ptrFromInt(0);
    bad.* = 0xDEAD;
}
noinline fn faultLevel2() void {
    faultLevel3();
}
noinline fn faultLevel1() void {
    faultLevel2();
}

/// Prove the interrupt path works end to end: raise #BP, have the handler run,
/// and return normally to the next instruction. If the IDT were wrong this
/// would triple-fault instead of printing.
fn selfTest() void {
    console.write("\n");
    console.info("self-test: raising int3 (breakpoint)...", .{});
    asm volatile ("int3");
    console.ok("returned from exception handler - interrupt path works", .{});
}

/// Total up usable RAM from the Limine memory map and print a summary.
fn reportMemory() void {
    const map = limine.memmap() orelse {
        console.warn("no memory map from bootloader", .{});
        return;
    };

    var usable: u64 = 0;
    var reclaimable: u64 = 0;
    var total: u64 = 0;

    var i: usize = 0;
    while (i < map.entry_count) : (i += 1) {
        const e = map.entries[i];
        total += e.length;
        switch (e.type) {
            .usable => usable += e.length,
            .bootloader_reclaimable, .acpi_reclaimable => reclaimable += e.length,
            else => {},
        }
    }

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    console.print("[ ok ] memory: {s} usable, {s} reclaimable, {s} total\n", .{
        fmt.humanBytes(&b1, usable),
        fmt.humanBytes(&b2, reclaimable),
        fmt.humanBytes(&b3, total),
    });
    console.print("[info] memory map: {d} regions\n", .{map.entry_count});
}

/// Draw the Orange OS boot banner: an orange bar, the name, and the version.
fn drawBanner() void {
    const f = framebuffer.get() orelse return;

    const orange = f.rgb(0xFF, 0x8C, 0x1A);
    const deep = f.rgb(0xC2, 0x5E, 0x00);

    // A two-tone accent bar across the top.
    f.fillRect(0, 0, f.width, 4, orange);
    f.fillRect(0, 4, f.width, 2, deep);

    fbcon.setColor(orange);
    fbcon.write("\n  Orange OS  ");
    fbcon.resetColor();
    fbcon.write("v" ++ VERSION ++ "  -  Zest kernel\n");
    fbcon.setColor(fbcon.theme.dim);
    fbcon.write("  a modern operating system, written from scratch\n");
    fbcon.resetColor();
}
