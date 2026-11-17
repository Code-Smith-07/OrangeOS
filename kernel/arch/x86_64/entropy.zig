//! Hardware randomness and a fast-changing counter on x86-64.

/// A counter that changes every few nanoseconds (the time stamp counter).
pub fn cycles() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return (@as(u64, high) << 32) | low;
}

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

fn hasRdrand() bool {
    return cpuid(1, 0)[2] & (1 << 30) != 0;
}
fn hasRdseed() bool {
    return cpuid(0, 0)[0] >= 7 and cpuid(7, 0)[1] & (1 << 18) != 0;
}

/// Does this processor have a random number instruction?
pub fn available() bool {
    return hasRdseed() or hasRdrand();
}

fn instruction(use_seed: bool) ?u64 {
    for (0..10) |_| {
        var value: u64 = undefined;
        var ok: u8 = undefined;
        if (use_seed) {
            asm volatile ("rdseed %[value]; setc %[ok]"
                : [value] "=r" (value),
                  [ok] "=r" (ok),
                :
                : "cc"
            );
        } else {
            asm volatile ("rdrand %[value]; setc %[ok]"
                : [value] "=r" (value),
                  [ok] "=r" (ok),
                :
                : "cc"
            );
        }
        if (ok != 0) return value;
    }
    return null;
}

/// One hardware random word, or null when the instruction is missing or
/// keeps failing. RDSEED is preferred: it is meant for seeding.
pub fn word() ?u64 {
    if (hasRdseed()) {
        if (instruction(true)) |value| return value;
    }
    return if (hasRdrand()) instruction(false) else null;
}
