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

    // ── 6. Memory. pmm -> vmm -> heap, in that order. ───────────────────────
    mm.init() catch |e| {
        console.err("memory init failed: {s}", .{@errorName(e)});
        io.hang();
    };
    mm.reportFragmentation();

    console.write("\n");
    console.ok("Phase 2 complete - Zest manages its own memory.", .{});
    console.info("next: ACPI, APIC, timer, interrupts enabled (Phase 3)", .{});

    if (build_options.mm_test) mm_test.runAll();

    // A deliberate breakpoint proves the IDT actually routes and returns.
    selfTest();

    if (build_options.fault_test) faultTest();

    io.hang();
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
