//! Per-task user TLS pointer. FS is not used by the kernel, but IA32_FS_BASE
//! is CPU-local and must be restored on every task switch, including migration.
const IA32_FS_BASE: u32 = 0xC000_0100;

pub fn set(base: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (IA32_FS_BASE),
          [lo] "{eax}" (@as(u32, @truncate(base))),
          [hi] "{edx}" (@as(u32, @truncate(base >> 32))),
        : "memory"
    );
}
