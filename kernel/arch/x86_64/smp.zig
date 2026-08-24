//! Symmetric multiprocessing — bringing up the application processors.
//!
//! The boot processor starts alone. Every other core sits halted until it
//! receives an INIT inter-processor interrupt followed by a Startup IPI naming
//! a page to begin executing at. The sequence and its timings come from the
//! Intel MP specification and are not negotiable: INIT, wait, SIPI, wait, and
//! a second SIPI if the core has not reported in, because some hardware misses
//! the first.

const std = @import("std");
const madt = @import("../../dev/acpi/madt.zig");
const apic = @import("apic.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const percpu = @import("percpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const tramp = @import("trampoline.zig");
const tsc = @import("../../time/tsc.zig");
const console = @import("../../console.zig");
const io = @import("io.zig");

/// LAPIC registers used only for IPI delivery.
const REG_ICR_LOW: usize = 0x300;
const REG_ICR_HIGH: usize = 0x310;

const DELIVERY_INIT: u32 = 5 << 8;
const DELIVERY_STARTUP: u32 = 6 << 8;
const LEVEL_ASSERT: u32 = 1 << 14;
const TRIGGER_LEVEL: u32 = 1 << 15;
const DELIVERY_PENDING: u32 = 1 << 12;

const AP_STACK_PAGES: usize = 4; // 16 KiB per core

var online: usize = 1; // the boot processor
var started: usize = 0;

pub fn cpusOnline() usize {
    return online;
}

fn params() *volatile tramp.Params {
    return @ptrFromInt(pmm.physToVirt(tramp.BASE + tramp.PARAMS_OFFSET));
}

fn sendIpi(apic_id: u8, low: u32) void {
    apic.writeIcrHigh(@as(u32, apic_id) << 24);
    apic.writeIcrLow(low);

    // Wait for the delivery status bit to clear before issuing another.
    const deadline = tsc.microsSinceBoot() + 100_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (apic.readIcrLow() & DELIVERY_PENDING == 0) return;
        asm volatile ("pause");
    }
}

/// Entry point for every application processor, in 64-bit mode on its own
/// stack. `index` arrives in rdi from the trampoline.
export fn apEntry(index: u64) callconv(.c) noreturn {
    const i: usize = @intCast(index);

    // Each core needs its own view of the CPU-local structures. The GDT and
    // IDT are shared and read-only in practice, so they can simply be loaded.
    gdt.init();
    idt.load();
    percpu.initAp(i, apic.id());

    apic.initAp();

    params().ready = 1;
    _ = @atomicRmw(usize, &online, .Add, 1, .seq_cst);

    // Nothing schedules across cores yet, so an AP parks. Waking here is
    // harmless: it simply halts again.
    while (true) {
        asm volatile ("hlt");
    }
}

/// Copy the trampoline into low memory and identity-map it.
fn prepareTrampoline() !void {
    const dest: [*]u8 = @ptrFromInt(pmm.physToVirt(tramp.BASE));
    const src = tramp.source();
    const n = tramp.size();
    if (n > tramp.PARAMS_OFFSET) return error.TrampolineTooLarge;

    var k: usize = 0;
    while (k < n) : (k += 1) dest[k] = src[k];

    // The AP is still executing at a low physical address when it turns paging
    // on, so that address must mean the same thing in the kernel's tables.
    try vmm.mapPage(
        vmm.kernelPml4(),
        tramp.BASE,
        tramp.BASE,
        vmm.PRESENT | vmm.WRITABLE,
    );
    vmm.invalidatePage(tramp.BASE);
}

pub fn init() !void {
    const total = madt.cpuCount();
    if (total <= 1) {
        console.info("SMP: single processor, nothing to start", .{});
        return;
    }

    try prepareTrampoline();

    const p = params();
    p.pml4 = vmm.kernelPml4();
    p.entry = @intFromPtr(&apEntry);

    const boot_id = apic.id();

    var i: usize = 0;
    while (i < total and i < percpu.MAX_CPUS) : (i += 1) {
        const target = madt.cpuApicId(i) orelse continue;
        if (target == boot_id) continue;

        // A fresh stack per core. They never share one.
        const order = pmm.orderFor(AP_STACK_PAGES);
        const stack_phys = pmm.allocOrder(order) catch continue;
        const stack_top = pmm.physToVirt(stack_phys) + AP_STACK_PAGES * pmm.PAGE_SIZE;

        p.stack_top = stack_top & ~@as(u64, 0xF);
        p.cpu_index = i;
        p.ready = 0;

        started += 1;

        // INIT, then two startup attempts. The 10 ms and 200 us waits are the
        // spec's, and shortening them makes cores intermittently not appear.
        sendIpi(target, DELIVERY_INIT | LEVEL_ASSERT | TRIGGER_LEVEL);
        tsc.busyWaitUs(10_000);

        const sipi = DELIVERY_STARTUP | @as(u32, @intCast(tramp.BASE >> 12));
        sendIpi(target, sipi);
        tsc.busyWaitUs(200);

        if (!waitReady(p, 100_000)) {
            sendIpi(target, sipi);
            _ = waitReady(p, 500_000);
        }
    }

    console.print("[ ok ] SMP: {d} of {d} processors online\n", .{ online, total });
}

fn waitReady(p: *volatile tramp.Params, timeout_us: u64) bool {
    const deadline = tsc.microsSinceBoot() + timeout_us;
    while (tsc.microsSinceBoot() < deadline) {
        if (p.ready != 0) return true;
        asm volatile ("pause");
    }
    return false;
}
