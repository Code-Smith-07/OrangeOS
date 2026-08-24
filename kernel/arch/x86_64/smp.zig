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
const sched = @import("../../sched/sched.zig");
const time = @import("../../time/time.zig");
const syscall_entry = @import("syscall_entry.zig");

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
    // Order matters, and not for the reason it looks like. Loading the GDT
    // reloads every segment register, and writing the GS *selector* zeroes
    // GS_BASE - in long mode the base survives only until something loads the
    // segment. So the per-CPU block must be established AFTER the GDT, never
    // before, or this core comes up with a null GS and faults on the first
    // %gs-relative access.
    gdt.initCpu(i);
    idt.load();
    percpu.initAp(i, apic.id());

    // SYSCALL is configured through per-CPU MSRs: EFER.SCE, STAR, LSTAR and
    // FMASK are all core-local. Skipping this on an application processor
    // makes the `syscall` instruction raise #UD the moment a task migrates
    // there - which is a fault in userspace with no obvious cause.
    syscall_entry.init();

    apic.initAp();

    // Every core needs its own idle task: idle is where a core goes when no
    // work is ready, and two cores cannot share one stack.
    sched.initCpu(i) catch {
        params().ready = 1;
        while (true) asm volatile ("hlt");
    };

    params().ready = 1;
    _ = @atomicRmw(usize, &online, .Add, 1, .seq_cst);

    // Signal that this core is ready, then wait until the boot processor has
    // finished starting everyone. Entering the scheduler before the run queues
    // are live would have this core pick work that does not exist yet.
    while (@atomicLoad(bool, &release_aps, .acquire) == false) {
        asm volatile ("pause");
    }

    // Each core drives its own preemption: the LAPIC timer is per-CPU, so a
    // core without one would run whatever it picked up until that task blocked.
    apic.startTimer(time.TICK_HZ);
    io.sti();

    sched.startAp();
}

/// Vector used to stop every other core when the kernel panics.
pub const VECTOR_PANIC_HALT: u8 = 0xF0;

/// Destination shorthand 0b11: every CPU except the one sending.
const SHORTHAND_ALL_BUT_SELF: u32 = 3 << 18;

var halt_handler_installed: bool = false;

fn panicHaltHandler(frame: *@import("isr.zig").TrapFrame) void {
    _ = frame;
    // No EOI and no return. This core is done: the machine is about to print
    // a panic and anything this core does from here would scribble over it.
    io.cli();
    while (true) asm volatile ("hlt");
}

pub fn installPanicHalt() void {
    if (halt_handler_installed) return;
    @import("isr.zig").register(VECTOR_PANIC_HALT, panicHaltHandler);
    halt_handler_installed = true;
}

/// Stop every other processor.
///
/// Without this a panic on one core is a race against the others: the
/// compositor keeps running on another CPU and paints over the panic output
/// as it is being written. Which is exactly what happened the first time this
/// was tested.
pub fn haltOtherCpus() void {
    if (online <= 1) return;

    sendIpi(0, SHORTHAND_ALL_BUT_SELF | (1 << 14) | VECTOR_PANIC_HALT);

    // Give them a moment to notice. Not waiting for acknowledgement: a core
    // that is wedged badly enough not to take an interrupt is exactly the
    // situation where blocking forever would hide the panic entirely.
    tsc.busyWaitUs(50_000);
}

/// Held false until the boot processor has brought everyone up and entered the
/// scheduler itself.
var release_aps: bool = false;

/// Let the application processors start scheduling.
pub fn releaseAps() void {
    @atomicStore(bool, &release_aps, true, .release);
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

        // Reserve this core's kernel and IST stacks here, on the boot
        // processor, while a failure is still recoverable by simply not
        // starting the core. Doing it inside apEntry would mean a core
        // already running discovers it has nowhere to take a fault.
        gdt.reserveStacks(i) catch continue;

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
