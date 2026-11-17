// Orange OS — Arm64 entry.
//
// The machine starts every processor here with the memory map off, running
// at the kernel's physical load address. This file:
//   1. leaves hypervisor level (EL2) for kernel level (EL1) if it was
//      started there;
//   2. turns the memory map on with a small fixed set of tables that give
//      the same layout the x86 kernel gets from its boot loader:
//        - every physical address at itself (so this code keeps running);
//        - every physical address again at HHDM + address ("direct map");
//        - the kernel image at 0xFFFFFFFF80000000.
//      The kernel later builds its real tables (mm/vmm.zig) and these are
//      only used again when another processor starts;
//   3. gives the processor its stack and calls kmain(processor index,
//      device tree address or 0).
//
// The first processor arrives at _start. The others are started later by
// the kernel (PSCI CPU_ON) at _secondary_start with their index in x0.

#define STACK_SHIFT   16                  // 64 KB a processor
#define MAX_CPUS      8
#define KERNEL_PHYS   0x40200000          // must match boot/linker-aarch64.ld

// Blocks (1 GB at level 1, 2 MB at level 2). Normal memory: read/write,
// cached, access flag set, never executable from user level. Device memory:
// uncached, never executable.
#define BLOCK_NORMAL  0x0040000000000701
#define BLOCK_DEVICE  0x0060000000000405
#define TABLE         0x3

// 48-bit addresses in both halves, 4 KB pages, cached page-table walks.
#define TCR_VALUE     0xB5103510
// Memory map, data cache and instruction cache on; the bits that must be 1;
// and what programs may do themselves: read the cache geometry (UCT), zero
// cache lines (DZE), clean caches for code they generate (UCI), and wait
// for an event or interrupt without a trap (nTWE, nTWI).
#define SCTLR_VALUE   0x34D5D805

    .section .boot.text, "ax"
    .global _start
_start:
    mov     x19, #0                       // processor index
    mov     x20, x0                       // device tree address, if a boot loader gave one
    b       enter

    .global _secondary_start
_secondary_start:
    mov     x19, x0                       // index given to PSCI CPU_ON
    mov     x20, #0

enter:
    msr     daifset, #0xf                 // no interrupts yet
    mrs     x1, CurrentEL
    lsr     x1, x1, #2
    cmp     x1, #2
    b.ne    at_el1

    // Started at EL2 (real hardware, or QEMU with virtualization=on):
    // make EL1 a 64-bit level that may use the timers and the interrupt
    // controller's registers, then drop to it.
    mov     x1, #(1 << 31)                // HCR_EL2.RW: EL1 is AArch64
    msr     hcr_el2, x1
    mov     x1, #3                        // EL1 may read the counters
    msr     cnthctl_el2, x1
    msr     cntvoff_el2, xzr
    mov     x1, #0x33ff                   // no FP/SIMD traps to EL2
    msr     cptr_el2, x1
    mrs     x1, id_aa64pfr0_el1
    ubfx    x1, x1, #24, #4               // GIC system registers present?
    cbz     x1, 1f
    mrs     x1, S3_4_C12_C9_5             // ICC_SRE_EL2
    orr     x1, x1, #0xf                  // SRE, DFB, DIB, Enable
    msr     S3_4_C12_C9_5, x1
    isb
1:
    mov     x1, #0x3c5                    // EL1 with its own stack, masked
    msr     spsr_el2, x1
    adr     x1, at_el1
    msr     elr_el2, x1
    eret

at_el1:
    adrp    x1, boot_root
    msr     ttbr0_el1, x1
    msr     ttbr1_el1, x1
    mov     x1, #0xff                     // attr 0 normal, attr 1 device
    msr     mair_el1, x1
    ldr     x1, =TCR_VALUE
    mrs     x2, id_aa64mmfr0_el1          // physical address size
    and     x2, x2, #7
    orr     x1, x1, x2, lsl #32
    msr     tcr_el1, x1
    mov     x1, #(3 << 20)                // FP/SIMD usable (user programs)
    msr     cpacr_el1, x1
    isb
    ldr     x1, =SCTLR_VALUE
    msr     sctlr_el1, x1
    isb

    // From here the upper-half addresses work.
    ldr     x1, =boot_stacks
    add     x2, x19, #1
    add     x1, x1, x2, lsl #STACK_SHIFT
    mov     sp, x1
    cbnz    x19, 3f

    ldr     x1, =__bss_start              // only the first processor
    ldr     x2, =__bss_end
2:  cmp     x1, x2
    b.hs    3f
    str     xzr, [x1], #8
    b       2b
3:
    mov     x29, #0
    mov     x30, #0
    mov     x0, x19
    mov     x1, x20
    ldr     x2, =kmain
    br      x2

    .ltorg

    .section .boot.data, "aw"
    .balign 4096
    .global boot_root
boot_root:
    .quad   boot_direct + TABLE           // 0: physical addresses as they are
    .fill   255, 8, 0
    .quad   boot_direct + TABLE           // 256: the direct map (HHDM)
    .fill   254, 8, 0
    .quad   boot_high + TABLE             // 511: the top 512 GB

boot_direct:
    .quad   BLOCK_DEVICE                  // 0 to 1 GB: serial, interrupt controller, virtio
    .set    gb, 1
    .rept   255                           // 1 to 256 GB: memory
    .quad   BLOCK_NORMAL + (gb << 30)
    .set    gb, gb + 1
    .endr
    .rept   256                           // 256 to 512 GB: PCI and high devices
    .quad   BLOCK_DEVICE + (gb << 30)
    .set    gb, gb + 1
    .endr

boot_high:
    .fill   510, 8, 0
    .quad   boot_kernel + TABLE           // 0xFFFFFFFF80000000: the kernel image
    .quad   0

boot_kernel:                              // 1 GB from the kernel's load address
    .set    mb2, 0
    .rept   512
    .quad   BLOCK_NORMAL + KERNEL_PHYS + (mb2 << 21)
    .set    mb2, mb2 + 1
    .endr

    .section .bss.stacks, "aw", %nobits
    .balign 4096
    .global boot_stacks
boot_stacks:
    .skip   MAX_CPUS << STACK_SHIFT
