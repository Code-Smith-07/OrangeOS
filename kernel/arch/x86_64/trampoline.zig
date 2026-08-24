//! Application processor startup trampoline.
//!
//! An AP begins execution in 16-bit real mode at a physical address the boot
//! processor chooses, which must be page-aligned and below 1 MiB. It has to
//! walk the whole way up to 64-bit long mode by itself: real mode, protected
//! mode, PAE, paging, then a far jump into 64-bit code.
//!
//! Two consequences shape the code below.
//!
//! First, it runs at a fixed physical address that has nothing to do with
//! where the linker put it, so every absolute reference is written as
//! `label - start + TRAMPOLINE_BASE`. Getting one of those wrong jumps into
//! nothing and the CPU simply never appears.
//!
//! Second, the page must be identity-mapped in the kernel's page tables before
//! paging is enabled, because the instruction pointer is still a low physical
//! address at the moment CR0.PG is set.

/// Where the trampoline is copied to, and the SIPI vector (0x8 → 0x8000).
pub const BASE: u64 = 0x8000;

/// Parameters are patched into the page at this offset, past the code.
pub const PARAMS_OFFSET: usize = 0xF00;

/// Written by the boot processor, read by the AP as it comes up.
pub const Params = extern struct {
    pml4: u64,
    stack_top: u64,
    entry: u64,
    cpu_index: u64,
    /// The AP sets this once it reaches 64-bit Zig code.
    ready: u64,
};

comptime {
    asm (
        \\.section .rodata
        \\.balign 16
        \\.global ap_trampoline_start
        \\.global ap_trampoline_end
        \\
        \\.set TRAMP, 0x8000
        \\.set PARAMS, TRAMP + 0xF00
        \\
        \\ap_trampoline_start:
        \\.code16
        \\    cli
        \\    cld
        \\    xorw %ax, %ax
        \\    movw %ax, %ds
        \\    movw %ax, %es
        \\    movw %ax, %ss
        \\
        \\    # Load a GDT describing 32-bit and 64-bit code segments.
        \\    lgdtl (gdt_desc - ap_trampoline_start + TRAMP)
        \\
        \\    movl %cr0, %eax
        \\    orl $1, %eax
        \\    movl %eax, %cr0
        \\    ljmpl $0x08, $(protected - ap_trampoline_start + TRAMP)
        \\
        \\.code32
        \\protected:
        \\    movw $0x10, %ax
        \\    movw %ax, %ds
        \\    movw %ax, %es
        \\    movw %ax, %ss
        \\    movw %ax, %fs
        \\    movw %ax, %gs
        \\
        \\    # PAE is required before long mode.
        \\    movl %cr4, %eax
        \\    orl $(1 << 5), %eax
        \\    movl %eax, %cr4
        \\
        \\    # Adopt the kernel's page tables.
        \\    movl (PARAMS), %eax
        \\    movl %eax, %cr3
        \\
        \\    # EFER.LME, and NXE so the kernel's NX bits are legal here too.
        \\    movl $0xC0000080, %ecx
        \\    rdmsr
        \\    orl $((1 << 8) | (1 << 11)), %eax
        \\    wrmsr
        \\
        \\    # Paging on. From here the identity mapping is what keeps us alive.
        \\    movl %cr0, %eax
        \\    orl $0x80000000, %eax
        \\    movl %eax, %cr0
        \\
        \\    ljmpl $0x18, $(long_mode - ap_trampoline_start + TRAMP)
        \\
        \\.code64
        \\long_mode:
        \\    movq $PARAMS, %rbx
        \\    movq 8(%rbx), %rsp
        \\    movq 24(%rbx), %rdi
        \\    movq 16(%rbx), %rax
        \\    jmpq *%rax
        \\
        \\.balign 16
        \\gdt:
        \\    .quad 0x0000000000000000
        \\    .quad 0x00CF9A000000FFFF
        \\    .quad 0x00CF92000000FFFF
        \\    .quad 0x00AF9A000000FFFF
        \\    .quad 0x00AF92000000FFFF
        \\gdt_end:
        \\
        \\gdt_desc:
        \\    .word gdt_end - gdt - 1
        \\    .long gdt - ap_trampoline_start + TRAMP
        \\
        \\ap_trampoline_end:
    );
}

pub extern const ap_trampoline_start: u8;
pub extern const ap_trampoline_end: u8;

pub fn size() usize {
    return @intFromPtr(&ap_trampoline_end) - @intFromPtr(&ap_trampoline_start);
}

pub fn source() [*]const u8 {
    return @ptrCast(&ap_trampoline_start);
}
