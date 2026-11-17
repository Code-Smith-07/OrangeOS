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
const arch = @import("../arch/arch.zig");
const limine = arch.boot;
const pte = arch.pte;
const mmu = arch.mmu;
const flags_mod = @import("page_flags.zig");

pub const PAGE_SIZE: usize = 4096;
pub const HUGE_2M: usize = 2 * 1024 * 1024;

// Page table entry flags.
pub const PRESENT = flags_mod.PRESENT;
pub const WRITABLE = flags_mod.WRITABLE;
pub const USER = flags_mod.USER;
pub const WRITE_THROUGH = flags_mod.WRITE_THROUGH;
pub const NO_CACHE = flags_mod.NO_CACHE;
pub const ACCESSED = flags_mod.ACCESSED;
pub const DIRTY = flags_mod.DIRTY;
pub const HUGE = flags_mod.HUGE;
pub const GLOBAL = flags_mod.GLOBAL;
pub const OWNED = flags_mod.OWNED;
pub const NO_EXECUTE = flags_mod.NO_EXECUTE;

const ADDR_MASK: u64 = pte.ADDR_MASK;

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

// A user page table can be walked by the kernel on one CPU (validating a
// syscall buffer) while a thread of the same program edits it on another.
// Entries are therefore read and written whole, never as a torn or cached
// value; the hardware walker reads them atomically too.
inline fn loadEntry(entry: *const u64) u64 {
    return @atomicLoad(u64, entry, .monotonic);
}

inline fn storeEntry(entry: *u64, value: u64) void {
    @atomicStore(u64, entry, value, .monotonic);
}

/// Walk to the next level, allocating a table if it isn't there yet.
fn nextTable(table: *[512]u64, index: usize, flags: u64) Error!*[512]u64 {
    const entry = loadEntry(&table[index]);
    if (!pte.present(entry)) {
        const phys = pmm.allocPageZeroed() catch return Error.OutOfMemory;
        storeEntry(&table[index], pte.table(phys, flags));
        return tableAt(phys);
    }
    // Intermediate entries must permit anything a leaf below might need; the
    // leaf's own flags do the actual restricting.
    const widened = pte.widen(entry, flags);
    if (widened != entry) storeEntry(&table[index], widened);
    return tableAt(widened);
}

/// Map one 4 KiB page.
pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: u64) Error!void {
    const pml4 = tableAt(pml4_phys);
    const inter = flags & (USER | WRITABLE);

    const pdpt = try nextTable(pml4, indexOf(virt, 3), inter);
    const pd = try nextTable(pdpt, indexOf(virt, 2), inter);
    const pt = try nextTable(pd, indexOf(virt, 1), inter);

    storeEntry(&pt[indexOf(virt, 0)], pte.leaf(phys, flags));
}

/// Map one 2 MiB page. The PD entry becomes a leaf.
pub fn mapHuge2M(pml4_phys: u64, virt: u64, phys: u64, flags: u64) Error!void {
    const pml4 = tableAt(pml4_phys);
    const inter = flags & (USER | WRITABLE);

    const pdpt = try nextTable(pml4, indexOf(virt, 3), inter);
    const pd = try nextTable(pdpt, indexOf(virt, 2), inter);

    pd[indexOf(virt, 1)] = pte.block(phys, flags);
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
    const e3 = loadEntry(&pml4[indexOf(virt, 3)]);
    if (!pte.present(e3)) return null;

    const pdpt = tableAt(e3);
    const e2 = loadEntry(&pdpt[indexOf(virt, 2)]);
    if (!pte.present(e2)) return null;
    if (pte.huge(e2)) return (e2 & ADDR_MASK) | (virt & 0x3FFF_FFFF);

    const pd = tableAt(e2);
    const e1 = loadEntry(&pd[indexOf(virt, 1)]);
    if (!pte.present(e1)) return null;
    if (pte.huge(e1)) return (e1 & ADDR_MASK) | (virt & 0x1F_FFFF);

    const pt = tableAt(e1);
    const e0 = loadEntry(&pt[indexOf(virt, 0)]);
    if (!pte.present(e0)) return null;
    return (e0 & ADDR_MASK) | (virt & 0xFFF);
}

/// Whether any page in [virt, virt + size) is mapped. Absent tables are
/// skipped whole, so checking a many-GiB reservation costs a few lookups per
/// populated 2 MiB block rather than one per page.
pub fn anyMapped(pml4_phys: u64, virt: u64, size: u64) bool {
    const end = virt + size;
    var address = virt;
    const pml4 = tableAt(pml4_phys);
    while (address < end) {
        const e3 = loadEntry(&pml4[indexOf(address, 3)]);
        if (!pte.present(e3)) {
            address = (address | ((1 << 39) - 1)) + 1;
            continue;
        }
        const e2 = loadEntry(&tableAt(e3)[indexOf(address, 2)]);
        if (!pte.present(e2)) {
            address = (address | ((1 << 30) - 1)) + 1;
            continue;
        }
        if (pte.huge(e2)) return true;
        const e1 = loadEntry(&tableAt(e2)[indexOf(address, 1)]);
        if (!pte.present(e1)) {
            address = (address | ((1 << 21) - 1)) + 1;
            continue;
        }
        if (pte.huge(e1)) return true;
        if (pte.present(loadEntry(&tableAt(e1)[indexOf(address, 0)]))) return true;
        address += PAGE_SIZE;
    }
    return false;
}

/// The first address in [virt, end) whose page table exists (so a page there
/// may be mapped), skipping absent tables whole; null if there is none.
pub fn nextPossiblyMapped(pml4_phys: u64, virt: u64, end: u64) ?u64 {
    var address = virt;
    const pml4 = tableAt(pml4_phys);
    while (address < end) {
        const e3 = loadEntry(&pml4[indexOf(address, 3)]);
        if (!pte.present(e3)) {
            address = (address | ((1 << 39) - 1)) + 1;
            continue;
        }
        const e2 = loadEntry(&tableAt(e3)[indexOf(address, 2)]);
        if (!pte.present(e2)) {
            address = (address | ((1 << 30) - 1)) + 1;
            continue;
        }
        if (pte.huge(e2)) return address;
        const e1 = loadEntry(&tableAt(e2)[indexOf(address, 1)]);
        if (!pte.present(e1)) {
            address = (address | ((1 << 21) - 1)) + 1;
            continue;
        }
        return address;
    }
    return null;
}

/// Return the leaf page-table entry flags for `virt`, or null if unmapped.
/// Used to verify that W^X actually took effect rather than assuming it did.
pub fn leafFlags(pml4_phys: u64, virt: u64) ?u64 {
    const pml4 = tableAt(pml4_phys);
    const e3 = loadEntry(&pml4[indexOf(virt, 3)]);
    if (!pte.present(e3)) return null;

    const pdpt = tableAt(e3);
    const e2 = loadEntry(&pdpt[indexOf(virt, 2)]);
    if (!pte.present(e2)) return null;
    if (pte.huge(e2)) return pte.flagsOf(e2);

    const pd = tableAt(e2);
    const e1 = loadEntry(&pd[indexOf(virt, 1)]);
    if (!pte.present(e1)) return null;
    if (pte.huge(e1)) return pte.flagsOf(e1);

    const pt = tableAt(e1);
    const e0 = loadEntry(&pt[indexOf(virt, 0)]);
    if (!pte.present(e0)) return null;
    return pte.flagsOf(e0);
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

/// Make `phys` the page table this processor walks (for user addresses on
/// processors that keep the kernel's table separately).
pub fn loadCr3(phys: u64) void {
    mmu.loadRoot(phys);
}

/// Forget this processor's cached translation of one page.
pub fn invalidatePage(virt: u64) void {
    mmu.invalidatePage(virt);
}

/// Drop every non-global translation on this CPU by reloading CR3. Cheaper
/// than invalidating a long range one page at a time.
pub fn flushLocal() void {
    loadCr3(currentCr3());
}

/// Does the kernel itself fault on writes to read-only pages?
pub fn writeProtectEnabled() bool {
    return mmu.writeProtectEnabled();
}

fn symAddr(sym: *u8) u64 {
    return @intFromPtr(sym);
}

pub fn init() !void {
    mmu.enableProtections();

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
    var lowest: u64 = ~@as(u64, 0);
    var i: usize = 0;
    while (i < mm.entry_count) : (i += 1) {
        const e = mm.entries[i];
        const top = e.base + e.length;
        if (top > highest) highest = top;
        if (e.base < lowest) lowest = e.base;
    }
    // On a PC the direct map covers everything from 0, device holes
    // included. On Arm the devices sit below memory and must not be mapped
    // as ordinary cached memory, so the map starts where memory starts and
    // each device gets its own uncached mapping (mapMmio).
    const hhdm_from: u64 = if (mmu.DIRECT_MAP_FROM_ZERO) 0 else std.mem.alignBackward(u64, lowest, HUGE_2M);
    const hhdm_size = std.mem.alignForward(u64, highest, HUGE_2M) - hhdm_from;
    try mapRangeHuge(kernel_pml4_phys, hhdm + hhdm_from, hhdm_from, @intCast(hhdm_size), PRESENT | WRITABLE | NO_EXECUTE);

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

    // Where the direct map does not cover the devices, the ones already in
    // use (the log port, the interrupt controller) need their own uncached
    // mappings before the switch, at the addresses they already have.
    if (!mmu.DIRECT_MAP_FROM_ZERO) {
        for (limine.deviceRegions()) |region| {
            try mapRange(kernel_pml4_phys, hhdm + region.base, region.base, @intCast(region.size), PRESENT | WRITABLE | NO_EXECUTE | NO_CACHE | WRITE_THROUGH);
        }
    }

    mmu.installKernelRoot(kernel_pml4_phys);
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
        if (!pte.present(e3)) continue;
        const pdpt = tableAt(e3);

        var l3: usize = 0;
        while (l3 < 512) : (l3 += 1) {
            const e2 = pdpt[l3];
            if (!pte.present(e2) or pte.huge(e2)) continue;
            const pd = tableAt(e2);

            var l2: usize = 0;
            while (l2 < 512) : (l2 += 1) {
                const e1 = pd[l2];
                if (!pte.present(e1) or pte.huge(e1)) continue;
                const pt = tableAt(e1);

                var l1: usize = 0;
                while (l1 < 512) : (l1 += 1) {
                    const e0 = pt[l1];
                    if (!pte.present(e0)) continue;
                    if (pte.owned(e0)) pmm.freePage(e0 & ADDR_MASK);
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
    errdefer pmm.freePage(phys);
    try mapPage(pml4_phys, virt, phys, flags | OWNED);
    return phys;
}

fn emptyTable(table: *const [512]u64) bool {
    for (table) |*entry| if (pte.present(loadEntry(entry))) return false;
    return true;
}

/// Reclaim empty lower-half page tables immediately. Only for an address
/// space no other CPU can be walking: a table freed here while another CPU
/// still caches the entry that pointed to it would be read after reuse.
pub fn pruneEmptyTables(pml4_phys: u64, virt: u64) void {
    var tables: [3]u64 = undefined;
    const count = unlinkEmptyTables(pml4_phys, virt, &tables);
    for (tables[0..count]) |phys| pmm.freePage(phys);
}

/// Unlink the empty page tables on `virt`'s path, deepest first, and return
/// their frames in `out` instead of freeing them. A shared address space must
/// invalidate the range on every CPU using it before freeing these, because
/// paging-structure caches may still hold the unlinked upper-level entries.
/// Never follows huge-page mappings or the shared kernel half.
pub fn unlinkEmptyTables(pml4_phys: u64, virt: u64, out: *[3]u64) usize {
    if (virt >= 0x0000_8000_0000_0000) return 0;
    var count: usize = 0;
    const pml4 = tableAt(pml4_phys);
    const e3 = &pml4[indexOf(virt, 3)];
    const e3_value = loadEntry(e3);
    if (!pte.present(e3_value)) return 0;
    const pdpt = tableAt(e3_value);
    const e2 = &pdpt[indexOf(virt, 2)];
    const e2_value = loadEntry(e2);
    if (pte.present(e2_value) and !pte.huge(e2_value)) {
        const pd = tableAt(e2_value);
        const e1 = &pd[indexOf(virt, 1)];
        const e1_value = loadEntry(e1);
        if (pte.present(e1_value) and !pte.huge(e1_value) and emptyTable(tableAt(e1_value))) {
            storeEntry(e1, 0);
            out[count] = e1_value & ADDR_MASK;
            count += 1;
        }
        if (emptyTable(pd)) {
            storeEntry(e2, 0);
            out[count] = e2_value & ADDR_MASK;
            count += 1;
        }
    }
    if (emptyTable(pdpt)) {
        storeEntry(e3, 0);
        out[count] = e3_value & ADDR_MASK;
        count += 1;
    }
    return count;
}

/// Clear a private lower-half leaf without freeing its page-table path. A
/// shared-space caller must invalidate remote CPUs before freeing the frame
/// or pruning the page tables.
pub fn detachPage(pml4_phys: u64, virt: u64) ?u64 {
    if (virt >= 0x0000_8000_0000_0000) return null;
    const pml4 = tableAt(pml4_phys);
    const e3 = loadEntry(&pml4[indexOf(virt, 3)]);
    if (!pte.present(e3)) return null;
    const e2 = loadEntry(&tableAt(e3)[indexOf(virt, 2)]);
    if (!pte.present(e2) or pte.huge(e2)) return null;
    const e1 = loadEntry(&tableAt(e2)[indexOf(virt, 1)]);
    if (!pte.present(e1) or pte.huge(e1)) return null;
    const leaf = &tableAt(e1)[indexOf(virt, 0)];
    const value = loadEntry(leaf);
    if (!pte.present(value)) return null;
    storeEntry(leaf, 0);
    return value & ADDR_MASK;
}

/// Remove one 4 KiB mapping in a caller-owned, single-task address space.
pub fn unmapPage(pml4_phys: u64, virt: u64) ?u64 {
    const phys = detachPage(pml4_phys, virt) orelse return null;
    invalidatePage(virt);
    pruneEmptyTables(pml4_phys, virt);
    return phys;
}

/// Clear a temporary kernel mapping without pruning its shared page-table path.
/// The caller must shoot down remote TLB entries before reusing the frame.
pub fn clearKernelPage(virt: u64) ?u64 {
    if (virt < 0xffff_8000_0000_0000) return null;
    const pml4 = tableAt(kernel_pml4_phys);
    const e3 = pml4[indexOf(virt, 3)];
    if (!pte.present(e3)) return null;
    const e2 = tableAt(e3)[indexOf(virt, 2)];
    if (!pte.present(e2) or pte.huge(e2)) return null;
    const e1 = tableAt(e2)[indexOf(virt, 1)];
    if (!pte.present(e1) or pte.huge(e1)) return null;
    const leaf = &tableAt(e1)[indexOf(virt, 0)];
    if (!pte.present(leaf.*)) return null;
    const phys = leaf.* & ADDR_MASK;
    leaf.* = 0;
    invalidatePage(virt);
    return phys;
}

pub fn currentCr3() u64 {
    return mmu.currentRoot();
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
