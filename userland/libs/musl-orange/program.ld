/* Orange OS — linker script for C and C++ programs on musl.
 *
 * Like userland/user.ld (load at 4 MiB, one page-aligned segment per
 * permission), but it keeps the unwind tables C++ exceptions need:
 * .eh_frame, the .eh_frame_hdr index the linker builds from it (described
 * by a PT_GNU_EH_FRAME program header, which libunwind finds through
 * dl_iterate_phdr), and the per-function .gcc_except_table landing pads.
 * It also collects .fini_array for musl's exit.
 */
OUTPUT_FORMAT(elf64-x86-64)
ENTRY(_start)

SECTIONS
{
    . = 0x400000;

    .text : { *(.text .text.*) }
    . = ALIGN(0x1000);
    .rodata : { *(.rodata .rodata.*) }
    .eh_frame_hdr : { *(.eh_frame_hdr) }
    .eh_frame : { KEEP(*(.eh_frame)) }
    .gcc_except_table : { *(.gcc_except_table .gcc_except_table.*) }
    . = ALIGN(0x1000);
    .init_array : {
        PROVIDE(__init_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE(__init_array_end = .);
    }
    .fini_array : {
        PROVIDE(__fini_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
        KEEP(*(.fini_array))
        PROVIDE(__fini_array_end = .);
    }
    .data.rel.ro : { *(.data.rel.ro .data.rel.ro.*) }
    . = ALIGN(0x1000);
    /* Thread-local storage: the PT_TLS image musl copies per thread. */
    .tdata : { *(.tdata .tdata.*) }
    .tbss  : { *(.tbss .tbss.*) }
    .data : { *(.data .data.*) }
    .bss  : { *(.bss .bss.*) *(COMMON) }

    /DISCARD/ : { *(.note .note.*) *(.comment) }
}
