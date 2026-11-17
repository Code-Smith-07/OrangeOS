/* Orange OS — Zest kernel linker script (Arm64, QEMU "virt" and alike)
 *
 * The machine loads the kernel at physical 0x40200000. RAM starts at
 * 0x40000000 and QEMU puts the device tree there, but only if the kernel
 * leaves it room (it reserves a full megabyte), hence the 2 MB gap. The
 * first section, .boot, runs there with the memory map off. Everything else
 * is linked at 0xFFFFFFFF80000000 and up, the same place the x86 kernel
 * lives, and runs once boot.S has turned the memory map on.
 */

OUTPUT_FORMAT(elf64-littleaarch64)
ENTRY(_start)

KERNEL_PHYS = 0x40200000;
/* Physical KERNEL_PHYS is virtual 0xFFFFFFFF80000000 (boot.S maps it so). */
KERNEL_OFFSET = 0xFFFFFFFF80000000 - KERNEL_PHYS;

PHDRS
{
    boot    PT_LOAD;
    text    PT_LOAD;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS
{
    . = KERNEL_PHYS;

    .boot : {
        KEEP(*(.boot.text))
        . = ALIGN(4096);
        KEEP(*(.boot.data))
    } :boot

    . = ALIGN(4096);
    . += KERNEL_OFFSET;
    __kernel_start = .;

    .text : AT(ADDR(.text) - KERNEL_OFFSET) {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    } :text

    . = ALIGN(4096);
    .rodata : AT(ADDR(.rodata) - KERNEL_OFFSET) {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } :rodata

    . = ALIGN(4096);
    .data : AT(ADDR(.data) - KERNEL_OFFSET) {
        __data_start = .;
        *(.data .data.*)
        /* Address tables the compiler makes, and the Limine request blocks
           shared files still declare (unused here): inside the image, so
           the kernel's own page tables map them. */
        *(.got .got.*)
        *(.limine_requests_start) *(.limine_requests) *(.limine_requests_end)
    } :data

    . = ALIGN(4096);
    .bss : AT(ADDR(.bss) - KERNEL_OFFSET) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data

    . = ALIGN(4096);
    __kernel_end = .;

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }
}
