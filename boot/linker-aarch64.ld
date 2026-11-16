/* Orange OS — Zest kernel linker script (Arm64, QEMU "virt" and alike)
 *
 * The machine loads the kernel at physical 0x40200000. RAM starts at
 * 0x40000000 and QEMU puts the device tree there, but only if the kernel
 * leaves it room (it reserves a full megabyte), hence the 2 MB gap. The first
 * section, .boot, runs there with the memory map off. Everything else is
 * linked in the upper half of the address space (physical address plus
 * KERNEL_VIRT) and runs once boot.S has turned the memory map on.
 */

OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

KERNEL_VIRT = 0xFFFFFF8000000000;

PHDRS
{
    boot    PT_LOAD;
    text    PT_LOAD;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS
{
    . = 0x40200000;

    .boot : {
        KEEP(*(.boot.text))
        . = ALIGN(4096);
        KEEP(*(.boot.data))
    } :boot

    . = ALIGN(4096);
    . += KERNEL_VIRT;
    __kernel_start = .;

    .text : AT(ADDR(.text) - KERNEL_VIRT) {
        *(.text .text.*)
    } :text

    . = ALIGN(4096);
    .rodata : AT(ADDR(.rodata) - KERNEL_VIRT) {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);
    .data : AT(ADDR(.data) - KERNEL_VIRT) {
        *(.data .data.*)
    } :data

    . = ALIGN(4096);
    .bss : AT(ADDR(.bss) - KERNEL_VIRT) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data

    __kernel_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
