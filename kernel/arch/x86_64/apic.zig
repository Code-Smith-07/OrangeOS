//! Local APIC — per-CPU interrupt controller and timer.
//!
//! Every CPU has one. It delivers device interrupts routed by the I/O APIC,
//! provides the per-CPU timer the scheduler will run on, and sends IPIs for
//! SMP in Phase 8.
//!
//! The LAPIC timer's tick rate is not documented anywhere and varies by
//! machine, so it has to be measured against the PIT at boot.

const io = @import("io.zig");
const vmm = @import("../../mm/vmm.zig");
const madt = @import("../../dev/acpi/madt.zig");
const pit = @import("../../time/pit.zig");
const isr = @import("isr.zig");

// Register offsets from the LAPIC MMIO base.
const REG_ID: usize = 0x020;
const REG_VERSION: usize = 0x030;
const REG_TPR: usize = 0x080;
const REG_EOI: usize = 0x0B0;
const REG_SPURIOUS: usize = 0x0F0;
const REG_LVT_TIMER: usize = 0x320;
const REG_LVT_LINT0: usize = 0x350;
const REG_LVT_LINT1: usize = 0x360;
const REG_LVT_ERROR: usize = 0x370;
const REG_TIMER_INIT: usize = 0x380;
const REG_TIMER_CURRENT: usize = 0x390;
const REG_TIMER_DIVIDE: usize = 0x3E0;

const SPURIOUS_ENABLE: u32 = 1 << 8;
const LVT_MASKED: u32 = 1 << 16;
const LVT_PERIODIC: u32 = 1 << 17;

const DIVIDE_BY_16: u32 = 0b0011;

pub const VECTOR_TIMER: u8 = 0x20;
pub const VECTOR_SPURIOUS: u8 = 0xFF;
pub const VECTOR_ERROR: u8 = 0xFE;

const IA32_APIC_BASE: u32 = 0x1B;

pub const Error = error{NoLapic} || vmm.Error;

var base_virt: u64 = 0;
var timer_ticks_per_ms: u32 = 0;
var enabled: bool = false;

inline fn read(offset: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(base_virt + offset);
    return p.*;
}

inline fn write(offset: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(base_virt + offset);
    p.* = value;
}

/// Signal end-of-interrupt. Without this the LAPIC will not deliver another
/// interrupt at the same or lower priority — the system goes quiet.
pub inline fn eoi() void {
    if (enabled) write(REG_EOI, 0);
}

fn readMsr(msr: u32) u64 {
    const low = asm volatile ("rdmsr"
        : [ret] "={eax}" (-> u32),
        : [msr] "{ecx}" (msr),
        : "edx"
    );
    const high = asm volatile ("rdmsr"
        : [ret] "={edx}" (-> u32),
        : [msr] "{ecx}" (msr),
        : "eax"
    );
    return (@as(u64, high) << 32) | low;
}

fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

pub fn init() Error!void {
    const phys = madt.lapicAddress();
    if (phys == 0) return Error.NoLapic;

    base_virt = try vmm.mapMmio(phys, 0x1000);

    // Global enable in IA32_APIC_BASE (bit 11). Usually already set, but a
    // firmware that left it clear would make every register read as zero.
    const apic_base = readMsr(IA32_APIC_BASE);
    writeMsr(IA32_APIC_BASE, apic_base | (1 << 11));

    // Accept all interrupt priorities.
    write(REG_TPR, 0);

    // Software-enable and set the spurious vector. Bit 8 is the enable.
    write(REG_SPURIOUS, SPURIOUS_ENABLE | VECTOR_SPURIOUS);

    // Mask the local interrupt pins; nothing is wired to them yet.
    write(REG_LVT_LINT0, LVT_MASKED);
    write(REG_LVT_LINT1, LVT_MASKED);
    write(REG_LVT_ERROR, VECTOR_ERROR);

    enabled = true;
}

/// Measure the LAPIC timer against a 10 ms PIT interval.
pub fn calibrateTimer() void {
    write(REG_TIMER_DIVIDE, DIVIDE_BY_16);
    write(REG_LVT_TIMER, LVT_MASKED); // count, but do not interrupt

    const CALIBRATION_US: u64 = 10_000;

    pit.armChannel2(CALIBRATION_US);
    write(REG_TIMER_INIT, 0xFFFF_FFFF);
    pit.waitChannel2();

    const remaining = read(REG_TIMER_CURRENT);
    write(REG_TIMER_INIT, 0); // stop
    pit.stopChannel2();

    const elapsed = 0xFFFF_FFFF - remaining;
    timer_ticks_per_ms = @intCast(elapsed / (CALIBRATION_US / 1000));
}

/// Start the periodic timer at `hz`.
pub fn startTimer(hz: u32) void {
    const count = (timer_ticks_per_ms * 1000) / hz;
    write(REG_TIMER_DIVIDE, DIVIDE_BY_16);
    write(REG_LVT_TIMER, LVT_PERIODIC | VECTOR_TIMER);
    write(REG_TIMER_INIT, if (count == 0) 1 else count);
}

pub fn stopTimer() void {
    write(REG_LVT_TIMER, LVT_MASKED);
    write(REG_TIMER_INIT, 0);
}

pub fn writeIcrHigh(value: u32) void {
    write(0x310, value);
}

pub fn writeIcrLow(value: u32) void {
    write(0x300, value);
}

pub fn readIcrLow() u32 {
    return read(0x300);
}

/// Software-enable this CPU's local APIC. Called on each application
/// processor: the enable bit is per-CPU, not global.
pub fn initAp() void {
    write(REG_TPR, 0);
    write(REG_SPURIOUS, SPURIOUS_ENABLE | VECTOR_SPURIOUS);
    write(REG_LVT_LINT0, LVT_MASKED);
    write(REG_LVT_LINT1, LVT_MASKED);
    write(REG_LVT_ERROR, VECTOR_ERROR);
}

pub fn id() u32 {
    return read(REG_ID) >> 24;
}

pub fn version() u32 {
    return read(REG_VERSION) & 0xFF;
}

pub fn timerTicksPerMs() u32 {
    return timer_ticks_per_ms;
}

pub fn isEnabled() bool {
    return enabled;
}
