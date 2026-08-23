//! Phase 3 bring-up: ACPI, interrupt controllers, timers, and `sti`.
//!
//! Order is load-bearing:
//!   1. ACPI tables parsed, so we know where the APICs are
//!   2. Legacy PIC remapped and masked, so it cannot inject into the
//!      exception vector range
//!   3. TSC calibrated against the PIT, while interrupts are still off and
//!      the measurement cannot be perturbed
//!   4. LAPIC enabled and its timer calibrated
//!   5. I/O APIC redirection table cleared and masked
//!   6. Tick handler registered, timer started
//!   7. Interrupts enabled

const acpi = @import("acpi.zig");
const madt = @import("madt.zig");
const apic = @import("../../arch/x86_64/apic.zig");
const ioapic = @import("../../arch/x86_64/ioapic.zig");
const pic = @import("../../arch/x86_64/pic.zig");
const io = @import("../../arch/x86_64/io.zig");
const tsc = @import("../../time/tsc.zig");
const time = @import("../../time/time.zig");
const console = @import("../../console.zig");
const fmt = @import("../../lib/fmt.zig");

pub fn init() !void {
    try acpi.init();
    console.print("[ ok ] ACPI {s} revision {d}, {d} tables\n", .{
        if (acpi.usingXsdt()) "XSDT" else "RSDT",
        acpi.revision(),
        acpi.tableCount(),
    });
    acpi.listTables();

    try madt.init();
    madt.report();

    pic.disable();
    console.ok("legacy 8259 PIC remapped and masked", .{});

    tsc.calibrate();
    var buf: [32]u8 = undefined;
    console.print("[ ok ] TSC calibrated: {s} MHz{s}\n", .{
        fmt.bufPrint(&buf, "{d}", .{tsc.frequencyHz() / 1_000_000}),
        if (tsc.isInvariant()) " (invariant)" else " (NOT invariant)",
    });

    try apic.init();
    console.print("[ ok ] LAPIC id {d}, version 0x{x}\n", .{ apic.id(), apic.version() });

    apic.calibrateTimer();
    console.print("[ ok ] LAPIC timer: {d} ticks/ms\n", .{apic.timerTicksPerMs()});

    ioapic.init() catch |e| {
        console.warn("I/O APIC init failed: {s}", .{@errorName(e)});
    };
    if (ioapic.ioApicCount() > 0) {
        console.print("[ ok ] I/O APIC: {d} controller(s), {d} interrupt lines\n", .{
            ioapic.ioApicCount(),
            ioapic.totalGsis(),
        });
    }

    time.init();
    io.sti();
    console.ok("interrupts enabled - system is preemptible", .{});
}
