//! Global Descriptor Table and Task State Segment.
//!
//! Long mode barely uses segmentation, but the GDT is still required: the CPU
//! needs valid code/data descriptors, and the TSS is what supplies the ring-0
//! stack pointer on privilege transitions plus the IST stacks that make
//! double-fault handling survivable.
//!
//! Every CPU gets its own GDT and its own TSS. That is not an optimisation:
//! the TSS holds rsp0, the kernel stack the CPU switches to on an interrupt
//! from ring 3. A shared TSS means every core lands on whichever core's stack
//! was written last, and two cores taking interrupts at once trample each
//! other. The IST stacks are per-CPU for the same reason.
//!
//! Selector layout is chosen for SYSCALL/SYSRET in Phase 4. SYSRET derives
//! SS from STAR[63:48]+8 and CS from STAR[63:48]+16, so user data must sit
//! immediately before user code:
//!
//!     0x00  null
//!     0x08  kernel code      <- STAR[47:32]
//!     0x10  kernel data
//!     0x18  user data        <- STAR[63:48] + 8
//!     0x20  user code        <- STAR[63:48] + 16
//!     0x28  TSS (16 bytes, occupies two entries)

const std = @import("std");
const percpu = @import("percpu.zig");
const pmm = @import("../../mm/pmm.zig");

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_DATA: u16 = 0x18;
pub const USER_CODE: u16 = 0x20;
pub const TSS_SEL: u16 = 0x28;

/// Stack sizes for the interrupt stack table. 16 KiB each — enough for a
/// panic path that formats and prints without itself overflowing.
const IST_STACK_SIZE = 16 * 1024;

pub const IST_DOUBLE_FAULT: u8 = 1;
pub const IST_NMI: u8 = 2;
pub const IST_MACHINE_CHECK: u8 = 3;

pub const MAX_CPUS = 32;

/// Slots within a CPU's stack block, in allocation order.
const SLOT_KERNEL = 0;
const SLOT_DF = 1;
const SLOT_NMI = 2;
const SLOT_MC = 3;
const STACKS_PER_CPU = 4;
const STACK_BLOCK = IST_STACK_SIZE * STACKS_PER_CPU;

/// The boot processor's stacks are static, and have to be: it needs a TSS
/// before the page allocator exists, and a fault arriving in that window has
/// to land somewhere real.
///
/// Every other core is a different story. An application processor is started
/// long after the allocator is up, so reserving MAX_CPUS worth of stacks
/// statically bought nothing and cost 2 MiB of .bss - four 512 KiB arrays
/// sized for 32 processors, on a machine that usually has four. That is most
/// of a 24 MiB idle-memory budget spent on cores that do not exist.
var bsp_stacks: [STACKS_PER_CPU][IST_STACK_SIZE]u8 align(16) = undefined;

/// Base of each CPU's stack block. Null until reserveStacks() runs for it.
var stack_base: [MAX_CPUS]?[*]u8 = .{null} ** MAX_CPUS;

/// Reserve a core's stacks. Called on the boot processor before that core is
/// started, never on the core itself: an AP that cannot get a stack must fail
/// before it is sent a SIPI, not after it is already running on one.
pub fn reserveStacks(index: usize) !void {
    if (index >= MAX_CPUS) return error.TooManyCpus;
    if (stack_base[index] != null) return;

    if (index == 0) {
        stack_base[0] = @ptrCast(&bsp_stacks);
        return;
    }

    const pages = STACK_BLOCK / pmm.PAGE_SIZE;
    const phys = try pmm.allocOrderZeroed(pmm.orderFor(pages));
    stack_base[index] = @ptrFromInt(pmm.physToVirt(phys));
}

/// A standard 8-byte descriptor. In long mode base and limit are ignored for
/// code/data, but the access and flag bits still matter.
const Entry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    accessed: bool = false,
    read_write: bool = false,
    direction: bool = false,
    executable: bool = false,
    descriptor_type: bool = false, // true = code/data, false = system
    dpl: u2 = 0,
    present: bool = false,
    limit_high: u4 = 0,
    available: bool = false,
    long_mode: bool = false,
    size_32: bool = false,
    granularity: bool = false,
    base_high: u8 = 0,

    fn code(dpl: u2) Entry {
        return .{
            .read_write = true,
            .executable = true,
            .descriptor_type = true,
            .dpl = dpl,
            .present = true,
            .long_mode = true,
        };
    }

    fn data(dpl: u2) Entry {
        return .{
            .read_write = true,
            .descriptor_type = true,
            .dpl = dpl,
            .present = true,
        };
    }
};

/// The TSS descriptor is 16 bytes — two GDT slots.
const TssDescriptor = packed struct(u128) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high_flags: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32 = 0,
};

/// 104-byte long-mode TSS. Only rsp0 and the IST entries are used.
const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1) = [_]u64{0} ** 7,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iomap_base: u16 align(1) = 0,
};

const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

var gdts: [MAX_CPUS][7]u64 align(16) = undefined;
var tsses: [MAX_CPUS]Tss = undefined;

/// Top of one slot in a CPU's stack block, 16-byte aligned. Stacks grow
/// downward, so the CPU wants the highest address.
fn stackTop(index: usize, slot: usize) u64 {
    const base = stack_base[index] orelse
        @panic("gdt: CPU stacks used before reserveStacks()");
    const addr = @intFromPtr(base) + (slot + 1) * IST_STACK_SIZE;
    return addr & ~@as(u64, 0xF);
}

pub fn init() void {
    reserveStacks(0) catch unreachable; // static storage, cannot fail
    initCpu(0);
}

/// Build and load this CPU's GDT and TSS.
pub fn initCpu(index: usize) void {
    const gdt = &gdts[index];
    const tss = &tsses[index];

    gdt[0] = 0;
    gdt[1] = @bitCast(Entry.code(0));
    gdt[2] = @bitCast(Entry.data(0));
    gdt[3] = @bitCast(Entry.data(3));
    gdt[4] = @bitCast(Entry.code(3));

    tss.* = .{};
    tss.rsp0 = stackTop(index, SLOT_KERNEL);
    tss.ist[IST_DOUBLE_FAULT - 1] = stackTop(index, SLOT_DF);
    tss.ist[IST_NMI - 1] = stackTop(index, SLOT_NMI);
    tss.ist[IST_MACHINE_CHECK - 1] = stackTop(index, SLOT_MC);
    // No I/O permission bitmap: point past the TSS limit.
    tss.iomap_base = @sizeOf(Tss);

    const tss_addr = @intFromPtr(tss);
    const tss_desc = TssDescriptor{
        .limit_low = @truncate(@sizeOf(Tss) - 1),
        .base_low = @truncate(tss_addr),
        .base_mid = @truncate(tss_addr >> 16),
        .access = 0x89, // present, type 9 = available 64-bit TSS
        .limit_high_flags = 0,
        .base_high = @truncate(tss_addr >> 24),
        .base_upper = @truncate(tss_addr >> 32),
    };
    const raw: u128 = @bitCast(tss_desc);
    gdt[5] = @truncate(raw);
    gdt[6] = @truncate(raw >> 64);

    const gdtr = Gdtr{
        .limit = @sizeOf([7]u64) - 1,
        .base = @intFromPtr(gdt),
    };

    load(&gdtr);
    loadTss();
}

/// Install the GDT and reload every segment register. CS cannot be loaded
/// with a mov, so we far-return into a new code selector.
fn load(gdtr: *const Gdtr) void {
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq %[kcode]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw %[kdata], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        :
        : [gdtr] "r" (gdtr),
          [kcode] "i" (@as(u64, KERNEL_CODE)),
          [kdata] "r" (@as(u16, KERNEL_DATA)),
        : "rax", "memory"
    );
}

fn loadTss() void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );
}

/// Called on every context switch so the CPU finds the right kernel stack
/// when a user thread traps. Writes THIS core's TSS: writing a shared one
/// would send another core's traps to this thread's stack.
pub fn setKernelStack(rsp: u64) void {
    tsses[percpu.cpuIndex()].rsp0 = rsp;
}
