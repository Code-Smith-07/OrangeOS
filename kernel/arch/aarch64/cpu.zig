//! Arm64 processor basics: the address layout, system registers, and the
//! firmware calls (PSCI) that start other processors and power the machine
//! off.

/// boot.S (and later mm/vmm.zig) maps physical memory at this offset: the
/// direct map, the same as the x86 kernel's.
pub const HHDM: u64 = 0xFFFF_8000_0000_0000;
/// Where the kernel image is linked, and the physical address that is.
/// Must match boot/linker-aarch64.ld.
pub const KERNEL_BASE: u64 = 0xFFFF_FFFF_8000_0000;
pub const KERNEL_PHYS: u64 = 0x4020_0000;
pub const MAX_CPUS = 8;

/// A physical address, seen through the direct map.
pub fn virt(physical: u64) u64 {
    return physical +% HHDM;
}
/// The physical address behind a kernel address: either something in the
/// kernel image (a static variable) or a direct-map address.
pub fn phys(virtual: u64) u64 {
    if (virtual >= KERNEL_BASE) return virtual - KERNEL_BASE + KERNEL_PHYS;
    return virtual -% HHDM;
}
pub fn ptr(comptime T: type, physical: u64) T {
    return @ptrFromInt(virt(physical));
}

pub inline fn read(comptime register: []const u8) u64 {
    return asm volatile ("mrs %[out], " ++ register
        : [out] "=r" (-> u64),
    );
}
pub inline fn write(comptime register: []const u8, value: u64) void {
    asm volatile ("msr " ++ register ++ ", %[in]"
        :
        : [in] "r" (value),
    );
}
pub inline fn isb() void {
    asm volatile ("isb");
}
pub inline fn interruptsOn() void {
    asm volatile ("msr daifclr, #2");
}
pub inline fn interruptsOff() void {
    asm volatile ("msr daifset, #2");
}
pub inline fn waitForInterrupt() void {
    asm volatile ("wfi");
}
pub inline fn relax() void {
    asm volatile ("yield");
}

/// The processor's hardware number, as the device tree and PSCI use it.
pub fn affinity() u64 {
    return read("mpidr_el1") & 0xFF_00FF_FFFF;
}

// ── Counter ────────────────────────────────────────────────────────────────
pub inline fn counter() u64 {
    isb();
    return read("cntvct_el0");
}
pub fn counterHz() u64 {
    return read("cntfrq_el0");
}
pub fn elapsedMicros(since: u64) u64 {
    return (counter() - since) * 1_000_000 / counterHz();
}
pub fn spinMicros(micros: u64) void {
    const start = counter();
    while (elapsedMicros(start) < micros) relax();
}

// ── PSCI: firmware calls ───────────────────────────────────────────────────
pub const Conduit = enum { hvc, smc };
pub var conduit: Conduit = .hvc;

const CPU_ON: u64 = 0xC400_0003;
const SYSTEM_OFF: u64 = 0x8400_0008;

fn firmware(function: u64, a: u64, b: u64, c: u64) i64 {
    return switch (conduit) {
        .hvc => asm volatile ("hvc #0"
            : [ret] "={x0}" (-> i64),
            : [f] "{x0}" (function),
              [a] "{x1}" (a),
              [b] "{x2}" (b),
              [c] "{x3}" (c),
            : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17"
        ),
        // "smc #0", spelled as its number: the assembler only accepts the
        // name when told the processor has a secure monitor.
        .smc => asm volatile (".inst 0xd4000003"
            : [ret] "={x0}" (-> i64),
            : [f] "{x0}" (function),
              [a] "{x1}" (a),
              [b] "{x2}" (b),
              [c] "{x3}" (c),
            : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17"
        ),
    };
}

/// Start the processor with hardware number `target` at physical address
/// `entry`, which receives `context` in x0. Zero means it was started.
pub fn startProcessor(target: u64, entry: u64, context: u64) i64 {
    return firmware(CPU_ON, target, entry, context);
}

pub fn powerOff() noreturn {
    _ = firmware(SYSTEM_OFF, 0, 0, 0);
    while (true) waitForInterrupt();
}
