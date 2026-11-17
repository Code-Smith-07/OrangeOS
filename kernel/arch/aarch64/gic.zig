//! GICv3: the Arm interrupt controller.
//!
//! Three parts: one distributor for the whole machine, one redistributor
//! per processor (found by matching the processor's hardware number), and
//! the processor's own interface, reached through system registers.

const cpu = @import("cpu.zig");
const percpu = @import("percpu.zig");

// Distributor.
const GICD_CTLR = 0x0000;
const CTLR_GROUP1: u32 = 1 << 1;
const CTLR_AFFINITY_ROUTING: u32 = 1 << 4;

// Redistributor: two 64 KB frames per processor.
const FRAME = 0x20000;
const GICR_TYPER = 0x0008;
const GICR_WAKER = 0x0014;
const WAKER_SLEEP: u32 = 1 << 1;
const WAKER_CHILDREN_ASLEEP: u32 = 1 << 2;
const TYPER_LAST: u64 = 1 << 4;
const SGI = 0x10000; // the second frame
const GICR_IGROUPR0 = SGI + 0x0080;
const GICR_ISENABLER0 = SGI + 0x0100;
const GICR_IPRIORITYR = SGI + 0x0400;

/// Returned by acknowledge() when nothing is waiting.
pub const SPURIOUS: u32 = 1023;

var distributor: u64 = 0;
var redistributors: u64 = 0;
var own: [percpu.MAX_CPUS]u64 = [_]u64{0} ** percpu.MAX_CPUS;

fn reg32(address: u64) *volatile u32 {
    return @ptrFromInt(address);
}

/// Once, on the first processor. Addresses are physical, from the device tree.
pub fn init(distributor_physical: u64, redistributors_physical: u64) void {
    distributor = cpu.virt(distributor_physical);
    redistributors = cpu.virt(redistributors_physical);
    reg32(distributor + GICD_CTLR).* = CTLR_AFFINITY_ROUTING | CTLR_GROUP1;
}

/// On every processor. False if this processor has no redistributor.
pub fn initProcessor() bool {
    const mpidr = cpu.read("mpidr_el1");
    const wanted: u64 = ((mpidr >> 32) & 0xFF) << 24 | (mpidr & 0xFF_FFFF);
    var frame = redistributors;
    const mine = while (true) : (frame += FRAME) {
        const typer = @as(*volatile u64, @ptrFromInt(frame + GICR_TYPER)).*;
        if (typer >> 32 == wanted) break frame;
        if (typer & TYPER_LAST != 0) return false;
    };
    own[percpu.cpuIndex()] = mine;

    reg32(mine + GICR_WAKER).* &= ~WAKER_SLEEP;
    while (reg32(mine + GICR_WAKER).* & WAKER_CHILDREN_ASLEEP != 0) cpu.relax();
    reg32(mine + GICR_IGROUPR0).* = 0xFFFF_FFFF; // all of them ordinary interrupts
    // Interrupts 0 to 15 are the ones processors send each other.
    for (0..16) |n| @as(*volatile u8, @ptrFromInt(mine + GICR_IPRIORITYR + n)).* = 0x90;
    reg32(mine + GICR_ISENABLER0).* = 0xFFFF;

    // The processor's interface: system registers on, accept every
    // priority, ordinary (group 1) interrupts on.
    cpu.write("S3_0_C12_C12_5", cpu.read("S3_0_C12_C12_5") | 1); // ICC_SRE_EL1
    cpu.isb();
    cpu.write("S3_0_C4_C6_0", 0xFF); // ICC_PMR_EL1
    cpu.write("S3_0_C12_C12_7", 1); // ICC_IGRPEN1_EL1
    cpu.isb();
    return true;
}

const GICD_IGROUPR = 0x0080;
const GICD_ISENABLER = 0x0100;
const GICD_IPRIORITYR = 0x0400;
const GICD_ICFGR = 0x0C00;
const GICD_IROUTER = 0x6000;

/// Let a device interrupt (32 and up) through, delivered to the processor
/// with hardware number `target`, level-triggered.
pub fn enableShared(interrupt: u32, target: u64) void {
    const word = interrupt / 32;
    const bit = @as(u32, 1) << @intCast(interrupt % 32);
    reg32(distributor + GICD_IGROUPR + word * 4).* |= bit;
    @as(*volatile u8, @ptrFromInt(distributor + GICD_IPRIORITYR + interrupt)).* = 0xA0;
    const cfg = reg32(distributor + GICD_ICFGR + (interrupt / 16) * 4);
    cfg.* &= ~(@as(u32, 2) << @intCast((interrupt % 16) * 2));
    @as(*volatile u64, @ptrFromInt(distributor + GICD_IROUTER + interrupt * 8)).* = target & 0xFF_00FF_FFFF;
    reg32(distributor + GICD_ISENABLER + word * 4).* = bit;
}

/// Let one of this processor's private interrupts (0 to 31) through.
pub fn enablePrivate(interrupt: u5) void {
    const mine = own[percpu.cpuIndex()];
    @as(*volatile u8, @ptrFromInt(mine + GICR_IPRIORITYR + interrupt)).* = 0xA0;
    reg32(mine + GICR_ISENABLER0).* = @as(u32, 1) << interrupt;
}

/// Which interrupt arrived (and tell the controller it is being handled).
pub fn acknowledge() u32 {
    return @truncate(cpu.read("S3_0_C12_C12_0") & 0xFF_FFFF); // ICC_IAR1_EL1
}

pub fn done(interrupt: u32) void {
    cpu.write("S3_0_C12_C12_1", interrupt); // ICC_EOIR1_EL1
}

/// Interrupt another processor. `target` is its hardware number; `number`
/// is 0 to 15.
pub fn sendToProcessor(target: u64, number: u4) void {
    const aff0 = target & 0xFF;
    const value = (((target >> 32) & 0xFF) << 48) | (((target >> 16) & 0xFF) << 32) | (((target >> 8) & 0xFF) << 16) |
        (@as(u64, number) << 24) | (@as(u64, 1) << @intCast(aff0 & 0xF));
    // Writing the SGI register is not ordered after earlier stores: without
    // this barrier the target can take the interrupt before it can see the
    // request it is about (a TLB shootdown then waits forever). x86 orders
    // its interrupt sends for free; Linux does the same here.
    asm volatile ("dsb ishst" ::: "memory");
    cpu.write("S3_0_C12_C11_5", value); // ICC_SGI1R_EL1
    cpu.isb();
}
