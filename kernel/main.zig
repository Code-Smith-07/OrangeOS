//! Orange OS — Zest kernel entry point.
//!
//! Phase 0: reach long mode via Limine, bring up serial, claim the
//! framebuffer, and report what the bootloader handed us.

const limine = @import("boot/limine_req.zig");
const serial = @import("drivers/char/serial.zig");
const framebuffer = @import("drivers/video/framebuffer.zig");
const fbcon = @import("drivers/video/fbcon.zig");
const console = @import("console.zig");
const io = @import("arch/x86_64/io.zig");
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

    console.write("\n");
    console.ok("Phase 0 complete - Zest is alive.", .{});
    console.info("next: GDT, IDT, exception handlers (Phase 1)", .{});

    io.hang();
}

/// Total up usable RAM from the Limine memory map and print a summary.
fn reportMemory() void {
    const mm = limine.memmap() orelse {
        console.warn("no memory map from bootloader", .{});
        return;
    };

    var usable: u64 = 0;
    var reclaimable: u64 = 0;
    var total: u64 = 0;

    var i: usize = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
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
    console.print("[info] memory map: {d} regions\n", .{mm.entry_count});
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
