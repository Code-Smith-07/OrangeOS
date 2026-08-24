//! Virtual memory manager — our own 4-level page tables.
//!
//! Limine hands us a working address space, but it belongs to the bootloader
//! and its bootloader-reclaimable memory has to be freed eventually. We build
//! our own PML4 with correct per-section permissions and switch CR3 to it.
//!
//! Three things get mapped:
//!   1. The kernel image, section by section: .text RX, .rodata R+NX,
//!      .data/.bss RW+NX. Limine maps the whole image RWX.
//!   2. The HHDM — all physical memory, RW+NX, using 2 MiB pages.
//!   3. The framebuffer, RW+NX write-combining.

const std = @import("std");
const pmm = @import("pmm.zig");
const limine = @import("../boot/limine_req.zig");

pub const PAGE_SIZE: usize = 4096;
pub const HUGE_2M: usize = 2 * 1024 * 1024;

// Page table entry flags.
pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const WRITE_THROUGH: u64 = 1 << 3;
pub const NO_CACHE: u64 = 1 << 4;
pub const ACCESSED: u64 = 1 << 5;
pub const DIRTY: u64 = 1 << 6;
pub const HUGE: u64 = 1 << 7;
pub const GLOBAL: u64 = 1 << 8;
pub const NO_EXECUTE: u64 = 1 << 63;

const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub const Error = error{OutOfMemory};

// Linker-provided section boundaries.
extern var __kernel_start: u8;
extern var __text_start: u8;
extern var __text_end: u8;
extern var __rodata_start: u8;
extern var __rodata_end: u8;
extern var __data_start: u8;
extern var __bss_end: u8;
extern var __kernel_end: u8;

var kernel_pml4_phys: u64 = 0;

inline fn tableAt(phys: u64) *[512]u64 {
    return @ptrFromInt(pmm.physToVirt(phys & ADDR_MASK));
}

inline fn indexOf(virt: u64, level: u6) usize {
    return @intCast((virt >> (12 + 9 * level)) & 0x1FF);
}

/// Walk to the next level, allocating a table if it isn't there yet.
fn nextTable(table: *[512]u64, index: usize, flags: u64) Error!*[512]u64 {
    if (table[index] & PRESENT == 0) {
        const phys = pmm.allocPageZeroed() catch return Error.OutOfMemory;
        table[index] = phys | PRESENT | WRITABLE | flags;
        return tableAt(phys);
    }
    // Intermediate entries must permit anything a leaf below might need; the
    // leaf's own flags do the actual restricting.
    table[index] |= flags & (WRITABLE | USER);
    return tableAt(table[index]);
}

/// Map one 4 KiB page.
pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: u64) Error!void {
    const pml4 = tableAt(pml4_phys);
    const inter = flags & (USER | WRITABLE);

    const pdpt = try nextTable(pml4, indexOf(virt, 3), inter);
    const pd = try nextTable(pdpt, indexOf(virt, 2), inter);
    const pt = try nextTable(pd, indexOf(virt, 1), inter);

    pt[indexOf(virt, 0)] = (phys & ADDR_MASK) | flags | PRESENT;
}

/// Map one 2 MiB page. The PD entry becomes a leaf.
pub fn mapHuge2M(pml4_phys: u64, virt: u64, phys: u64, flags: u64) Error!void {
    const pml4 = tableAt(pml4_phys);
    const inter = flags & (USER | WRITABLE);

    const pdpt = try nextTable(pml4, indexOf(virt, 3), inter);
    const pd = try nextTable(pdpt, indexOf(virt, 2), inter);

    pd[indexOf(virt, 1)] = (phys & ADDR_MASK) | flags | PRESENT | HUGE;
}

/// Map a range with 4 KiB pages.
pub fn mapRange(pml4_phys: u64, virt: u64, phys: u64, size: usize, flags: u64) Error!void {
    var off: usize = 0;
    while (off < size) : (off += PAGE_SIZE) {
        try mapPage(pml4_phys, virt + off, phys + off, flags);
    }
}

/// Map a range preferring 2 MiB pages, falling back to 4 KiB at the edges.
pub fn mapRangeHuge(pml4_phys: u64, virt: u64, phys: u64, size: usize, flags: u64) Error!void {
    var off: usize = 0;
    while (off < size) {
        const remaining = size - off;
        const aligned = (virt + off) % HUGE_2M == 0 and (phys + off) % HUGE_2M == 0;
        if (aligned and remaining >= HUGE_2M) {
            try mapHuge2M(pml4_phys, virt + off, phys + off, flags);
            off += HUGE_2M;
        } else {
            try mapPage(pml4_phys, virt + off, phys + off, flags);
            off += PAGE_SIZE;
        }
    }
}

/// Resolve a virtual address to physical, or null if unmapped.
pub fn translate(pml4_phys: u64, virt: u64) ?u64 {
    const pml4 = tableAt(pml4_phys);
    const e3 = pml4[indexOf(virt, 3)];
    if (e3 & PRESENT == 0) return null;

    const pdpt = tableAt(e3);
    const e2 = pdpt[indexOf(virt, 2)];
    if (e2 & PRESENT == 0) return null;
    if (e2 & HUGE != 0) return (e2 & ADDR_MASK) | (virt & 0x3FFF_FFFF);

    const pd = tableAt(e2);
    const e1 = pd[indexOf(virt, 1)];
    if (e1 & PRESENT == 0) return null;
    if (e1 & HUGE != 0) return (e1 & ADDR_MASK) | (virt & 0x1F_FFFF);

    const pt = tableAt(e1);
    const e0 = pt[indexOf(virt, 0)];
    if (e0 & PRESENT == 0) return null;
    return (e0 & ADDR_MASK) | (virt & 0xFFF);
}

/// Return the leaf page-table entry flags for `virt`, or null if unmapped.
/// Used to verify that W^X actually took effect rather than assuming it did.
pub fn leafFlags(pml4_phys: u64, virt: u64) ?u64 {
    const pml4 = tableAt(pml4_phys);
    const e3 = pml4[indexOf(virt, 3)];
    if (e3 & PRESENT == 0) return null;

    const pdpt = tableAt(e3);
    const e2 = pdpt[indexOf(virt, 2)];
    if (e2 & PRESENT == 0) return null;
    if (e2 & HUGE != 0) return e2 & ~ADDR_MASK;

    const pd = tableAt(e2);
    const e1 = pd[indexOf(virt, 1)];
    if (e1 & PRESENT == 0) return null;
    if (e1 & HUGE != 0) return e1 & ~ADDR_MASK;

    const pt = tableAt(e1);
    const e0 = pt[indexOf(virt, 0)];
    if (e0 & PRESENT == 0) return null;
    return e0 & ~ADDR_MASK;
}

pub fn textStart() u64 {
    return symAddr(&__text_start);
}

pub fn rodataStart() u64 {
    return symAddr(&__rodata_start);
}

pub fn dataStart() u64 {
    return symAddr(&__data_start);
}

pub fn loadCr3(phys: u64) void {
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

fn symAddr(sym: *u8) u64 {
    return @intFromPtr(sym);
}

pub fn init() !void {
    enableNx();
    enableWriteProtect();

    const exec = limine.executableAddress() orelse return error.NoExecutableAddress;
    const hhdm = pmm.hhdmBase();

    kernel_pml4_phys = try pmm.allocPageZeroed();

    // ── Kernel image ────────────────────────────────────────────────────────
    // Limine maps the whole image RWX. We split it so a bug that corrupts a
    // function pointer into .rodata faults instead of executing.
    //
    // The whole image is mapped RW+NX first, then .text and .rodata are
    // re-mapped with tighter flags on top. Mapping only the named sections
    // would leave gaps: .limine_requests sits between __rodata_end and
    // __data_start, and we still read Limine's responses after loading CR3.
    const kbase_virt = symAddr(&__kernel_start);

    const img_start = std.mem.alignBackward(u64, kbase_virt, PAGE_SIZE);
    const img_end = std.mem.alignForward(u64, symAddr(&__kernel_end), PAGE_SIZE);
    try mapRange(
        kernel_pml4_phys,
        img_start,
        exec.physical_base + (img_start - kbase_virt),
        @intCast(img_end - img_start),
        PRESENT | WRITABLE | NO_EXECUTE,
    );

    const Section = struct { start: u64, end: u64, flags: u64 };
    const tighten = [_]Section{
        // Executable, not writable.
        .{ .start = symAddr(&__text_start), .end = symAddr(&__text_end), .flags = PRESENT },
        // Read-only, not executable.
        .{ .start = symAddr(&__rodata_start), .end = symAddr(&__rodata_end), .flags = PRESENT | NO_EXECUTE },
    };

    for (tighten) |s| {
        const start = std.mem.alignBackward(u64, s.start, PAGE_SIZE);
        const end = std.mem.alignForward(u64, s.end, PAGE_SIZE);
        if (end <= start) continue;
        const phys = exec.physical_base + (start - kbase_virt);
        try mapRange(kernel_pml4_phys, start, phys, @intCast(end - start), s.flags);
    }

    // ── HHDM: every physical page, RW, never executable ──────────────────────
    const mm = limine.memmap() orelse return error.NoMemoryMap;
    var highest: u64 = 0;
    var i: usize = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
        const top = e.base + e.length;
        if (top > highest) highest = top;
    }
    const hhdm_size = std.mem.alignForward(u64, highest, HUGE_2M);
    try mapRangeHuge(kernel_pml4_phys, hhdm, 0, @intCast(hhdm_size), PRESENT | WRITABLE | NO_EXECUTE);

    // ── Framebuffer ─────────────────────────────────────────────────────────
    if (limine.framebuffers()) |fbr| {
        if (fbr.framebuffer_count > 0) {
            const fb = fbr.framebuffers[0];
            const fb_virt = @intFromPtr(fb.address);
            const fb_size = std.mem.alignForward(u64, fb.pitch * fb.height, PAGE_SIZE);
            if (translate(kernel_pml4_phys, fb_virt) == null) {
                const fb_phys = fb_virt - hhdm;
                try mapRangeHuge(
                    kernel_pml4_phys,
                    fb_virt,
                    fb_phys,
                    @intCast(fb_size),
                    PRESENT | WRITABLE | NO_EXECUTE | WRITE_THROUGH,
                );
            }
        }
    }

    loadCr3(kernel_pml4_phys);
}

/// Create a fresh address space for a user process.
///
/// The upper half (PML4 entries 256-511) is shared with the kernel by copying
/// its top-level entries. That means a syscall or interrupt taken while a user
/// process is running finds the kernel already mapped, with no CR3 switch —
/// which is what makes syscalls cheap. The lower half starts empty, so one
/// process cannot see another's memory.
pub fn createAddressSpace() Error!u64 {
    const phys = pmm.allocPageZeroed() catch return Error.OutOfMemory;
    const new_table = tableAt(phys);
    const kernel_table = tableAt(kernel_pml4_phys);

    var i: usize = 256;
    while (i < 512) : (i += 1) new_table[i] = kernel_table[i];

    return phys;
}

/// Free a user address space: every lower-half mapping and the tables that
/// held them. Upper-half entries are the kernel's and are left alone.
pub fn destroyAddressSpace(pml4_phys: u64) void {
    const pml4 = tableAt(pml4_phys);

    var l4: usize = 0;
    while (l4 < 256) : (l4 += 1) {
        const e3 = pml4[l4];
        if (e3 & PRESENT == 0) continue;
        const pdpt = tableAt(e3);

        var l3: usize = 0;
        while (l3 < 512) : (l3 += 1) {
            const e2 = pdpt[l3];
            if (e2 & PRESENT == 0 or e2 & HUGE != 0) continue;
            const pd = tableAt(e2);

            var l2: usize = 0;
            while (l2 < 512) : (l2 += 1) {
                const e1 = pd[l2];
                if (e1 & PRESENT == 0 or e1 & HUGE != 0) continue;
                const pt = tableAt(e1);

                var l1: usize = 0;
                while (l1 < 512) : (l1 += 1) {
                    const e0 = pt[l1];
                    if (e0 & PRESENT == 0) continue;
                    pmm.freePage(e0 & ADDR_MASK);
                }
                pmm.freePage(e1 & ADDR_MASK);
            }
            pmm.freePage(e2 & ADDR_MASK);
        }
        pmm.freePage(e3 & ADDR_MASK);
    }

    pmm.freePage(pml4_phys);
}

/// Allocate a physical page and map it into `pml4` at `virt`.
pub fn allocAndMap(pml4_phys: u64, virt: u64, flags: u64) Error!u64 {
    const phys = pmm.allocPageZeroed() catch return Error.OutOfMemory;
    try mapPage(pml4_phys, virt, phys, flags);
    return phys;
}

pub fn currentCr3() u64 {
    return asm volatile ("movq %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

/// Map a physical MMIO range into the HHDM window and return its virtual
/// address. Device registers must be uncached: the CPU caching a status
/// register would read stale values forever.
pub fn mapMmio(phys: u64, size: usize) Error!u64 {
    const aligned_phys = std.mem.alignBackward(u64, phys, PAGE_SIZE);
    const offset = phys - aligned_phys;
    const total = std.mem.alignForward(usize, size + offset, PAGE_SIZE);
    const virt = pmm.physToVirt(aligned_phys);

    try mapRange(
        kernel_pml4_phys,
        virt,
        aligned_phys,
        total,
        PRESENT | WRITABLE | NO_EXECUTE | NO_CACHE | WRITE_THROUGH,
    );

    var off: usize = 0;
    while (off < total) : (off += PAGE_SIZE) invalidatePage(virt + off);

    return virt + offset;
}

pub fn kernelPml4() u64 {
    return kernel_pml4_phys;
}
