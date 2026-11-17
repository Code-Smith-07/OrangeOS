//! x86-64 memory management unit: CR3, TLB, NX and write protection.

pub fn loadRoot(phys: u64) void {
    asm volatile ("movq %[p], %%cr3"
        :
        : [p] "r" (phys),
        : "memory"
    );
}

pub fn invalidatePage(virt: u64) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : "memory"
    );
}

pub fn currentRoot() u64 {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

/// The kernel's own table: on x86 it is simply the active one.
pub fn installKernelRoot(phys: u64) void {
    loadRoot(phys);
}

/// Called once before the kernel's page tables are built.
pub fn enableProtections() void {
    enableNx();
    enableWriteProtect();
}

/// Enable NX. Without this, setting bit 63 on a PTE causes a reserved-bit
/// page fault instead of marking the page non-executable.
fn enableNx() void {
    const IA32_EFER: u32 = 0xC000_0080;
    const NXE: u64 = 1 << 11;

    // One rdmsr, both halves from the same instruction. Two separate rdmsr
    // instructions taking eax from one and edx from the other is not a 64-bit
    // read - the compiler may schedule them independently.
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (IA32_EFER),
    );
    const efer = (@as(u64, high) << 32) | low;
    const updated = efer | NXE;

    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (IA32_EFER),
          [lo] "{eax}" (@as(u32, @truncate(updated))),
          [hi] "{edx}" (@as(u32, @truncate(updated >> 32))),
    );
}

/// Set CR0.WP. Without it, ring 0 may write to pages marked read-only, which
/// would make the .text/.rodata protections above decorative. Limine happens
/// to set it, but inheriting a security property from the bootloader is not
/// something to rely on.
fn enableWriteProtect() void {
    const WP: u64 = 1 << 16;
    const cr0 = asm volatile ("movq %%cr0, %[out]"
        : [out] "=r" (-> u64),
    );
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (cr0 | WP),
        : "memory"
    );
}

pub fn writeProtectEnabled() bool {
    const cr0 = asm volatile ("movq %%cr0, %[out]"
        : [out] "=r" (-> u64),
    );
    return cr0 & (1 << 16) != 0;
}

/// The direct map starts at physical 0 and covers everything below the
/// highest address in the memory map, device holes included.
pub const DIRECT_MAP_FROM_ZERO = true;

/// x86 keeps instruction fetch coherent with stores by itself.
pub fn syncInstructions() void {}
