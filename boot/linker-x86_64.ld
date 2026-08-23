/* Orange OS — Zest kernel linker script (x86_64)
 *
 * The kernel is loaded by Limine into the topmost 2 GiB of the address space
 * (0xFFFFFFFF80000000), which is what -mcmodel=kernel assumes. Sections are
 * page-aligned and separated so each can carry distinct page permissions:
 * .text executable, .rodata read-only + NX, .data/.bss writable + NX.
 */

OUTPUT_FORMAT(elf64-x86-64)
ENTRY(kmain)

PHDRS
{
    text    PT_LOAD;
    rodata  PT_LOAD;
    data    PT_LOAD;
}

SECTIONS
{
    /* Top-2GiB: required by the kernel code model. */
    . = 0xFFFFFFFF80000000;

    __kernel_start = .;

    .text : {
        __text_start = .;
        *(.text .text.*)
        __text_end = .;
    } :text

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .rodata : {
        __rodata_start = .;
        *(.rodata .rodata.*)
        __rodata_end = .;
    } :rodata

    /* Limine scans for its request magic here. Keep it in a loaded section. */
    .limine_requests : {
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :rodata

    . = ALIGN(CONSTANT(MAXPAGESIZE));

    .data : {
        __data_start = .;
        *(.data .data.*)
        __data_end = .;
    } :data

    .bss : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } :data

    __kernel_end = .;

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
