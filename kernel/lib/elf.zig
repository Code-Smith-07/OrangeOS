//! ELF64 parsing and loading.
//!
//! Loads a static executable into a user address space: walk the program
//! headers, map each PT_LOAD segment with the permissions it asks for, copy
//! the file bytes in, and zero the rest (which is how .bss is expressed —
//! memsz larger than filesz).

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");

pub const Error = error{
    NotElf,
    NotElf64,
    NotLittleEndian,
    WrongArchitecture,
    NotExecutable,
    BadProgramHeader,
    SegmentOutOfRange,
} || vmm.Error;

const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;

const PF_X: u32 = 1;
const PF_W: u32 = 2;
const PF_R: u32 = 4;

/// Userspace must live in the lower half. Refusing anything else stops a
/// malformed or hostile binary from asking to be mapped over the kernel.
const USER_MAX: u64 = 0x0000_8000_0000_0000;

pub const Header = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

pub const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    align_: u64,
};

pub const Loaded = struct {
    entry: u64,
    /// Highest mapped address, so the heap can start above it.
    brk: u64,
};

fn validate(hdr: *align(1) const Header) Error!void {
    if (!std.mem.eql(u8, hdr.ident[0..4], &ELF_MAGIC)) return Error.NotElf;
    if (hdr.ident[4] != 2) return Error.NotElf64; // EI_CLASS
    if (hdr.ident[5] != 1) return Error.NotLittleEndian; // EI_DATA
    if (hdr.machine != EM_X86_64) return Error.WrongArchitecture;
    if (hdr.type != ET_EXEC) return Error.NotExecutable;
}

/// Load `image` into the address space rooted at `pml4_phys`.
pub fn load(pml4_phys: u64, image: []const u8) Error!Loaded {
    if (image.len < @sizeOf(Header)) return Error.NotElf;
    const hdr: *align(1) const Header = @ptrCast(image.ptr);
    try validate(hdr);

    if (hdr.phoff + @as(u64, hdr.phnum) * hdr.phentsize > image.len) {
        return Error.BadProgramHeader;
    }

    var brk: u64 = 0;

    var i: usize = 0;
    while (i < hdr.phnum) : (i += 1) {
        const ph: *align(1) const ProgramHeader =
            @ptrCast(image.ptr + hdr.phoff + i * hdr.phentsize);
        if (ph.type != PT_LOAD or ph.memsz == 0) continue;

        if (ph.vaddr >= USER_MAX or ph.vaddr + ph.memsz > USER_MAX) {
            return Error.SegmentOutOfRange;
        }
        if (ph.offset + ph.filesz > image.len) return Error.BadProgramHeader;

        // Permissions come from the segment, so .text lands read-execute and
        // .data read-write — the same W^X discipline the kernel uses.
        var flags: u64 = vmm.PRESENT | vmm.USER;
        if (ph.flags & PF_W != 0) flags |= vmm.WRITABLE;
        if (ph.flags & PF_X == 0) flags |= vmm.NO_EXECUTE;

        const start = std.mem.alignBackward(u64, ph.vaddr, vmm.PAGE_SIZE);
        const end = std.mem.alignForward(u64, ph.vaddr + ph.memsz, vmm.PAGE_SIZE);

        var page = start;
        while (page < end) : (page += vmm.PAGE_SIZE) {
            // A page may already be mapped when two segments share one.
            const existing = vmm.translate(pml4_phys, page);
            const phys = if (existing) |p| p else try vmm.allocAndMap(pml4_phys, page, flags);
            if (existing != null) try vmm.mapPage(pml4_phys, page, phys, flags);

            // Copy this page's slice of the segment through the HHDM.
            const dest: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
            const page_start = page;
            const copy_from = @max(page_start, ph.vaddr);
            const file_end = ph.vaddr + ph.filesz;
            const copy_to = @min(page_start + vmm.PAGE_SIZE, file_end);

            if (copy_to > copy_from) {
                const dst_off = copy_from - page_start;
                const src_off = ph.offset + (copy_from - ph.vaddr);
                const n = copy_to - copy_from;
                @memcpy(
                    dest[dst_off .. dst_off + n],
                    image[src_off .. src_off + n],
                );
            }
        }

        if (end > brk) brk = end;
    }

    return .{ .entry = hdr.entry, .brk = brk };
}
