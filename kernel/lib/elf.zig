//! ELF64 parsing and loading.
//!
//! Loads a static executable into a user address space: walk the program
//! headers, map each PT_LOAD segment with the permissions it asks for, copy
//! the file bytes in, and zero the rest (which is how .bss is expressed —
//! memsz larger than filesz).

const std = @import("std");
const vmm = @import("../mm/vmm.zig");
const pmm = @import("../mm/pmm.zig");
const vfs = @import("../fs/vfs/vfs.zig");

pub const Error = error{
    NotElf,
    NotElf64,
    NotLittleEndian,
    WrongArchitecture,
    NotExecutable,
    BadProgramHeader,
    SegmentOutOfRange,
    IoError,
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

fn readExact(node: *const vfs.Node, offset: u64, dest: []u8) Error!void {
    var done: usize = 0;
    while (done < dest.len) {
        const pos = std.math.add(u64, offset, done) catch return Error.BadProgramHeader;
        const got = vfs.readAt(node, pos, dest[done..]) catch return Error.IoError;
        if (got == 0) return Error.IoError;
        done += got;
    }
}

/// Load directly from a filesystem node, using only ELF metadata and one
/// destination page at a time. Large files no longer require a kernel heap
/// buffer holding their entire contents.
pub fn loadFromNode(pml4_phys: u64, node: *const vfs.Node) Error!Loaded {
    if (node.size() < @sizeOf(Header)) return Error.NotElf;
    var hdr: Header = undefined;
    try readExact(node, 0, std.mem.asBytes(&hdr));
    try validate(&hdr);

    if (hdr.phentsize < @sizeOf(ProgramHeader)) return Error.BadProgramHeader;
    const table_size = std.math.mul(u64, hdr.phnum, hdr.phentsize) catch return Error.BadProgramHeader;
    const table_end = std.math.add(u64, hdr.phoff, table_size) catch return Error.BadProgramHeader;
    if (table_end > node.size()) return Error.BadProgramHeader;

    var brk: u64 = 0;

    var i: usize = 0;
    while (i < hdr.phnum) : (i += 1) {
        var ph: ProgramHeader = undefined;
        const ph_offset = hdr.phoff + i * @as(u64, hdr.phentsize);
        try readExact(node, ph_offset, std.mem.asBytes(&ph));
        if (ph.type != PT_LOAD or ph.memsz == 0) continue;

        const memory_end = std.math.add(u64, ph.vaddr, ph.memsz) catch return Error.SegmentOutOfRange;
        if (ph.vaddr >= USER_MAX or memory_end > USER_MAX or ph.filesz > ph.memsz) {
            return Error.SegmentOutOfRange;
        }
        const file_limit = std.math.add(u64, ph.offset, ph.filesz) catch return Error.BadProgramHeader;
        if (file_limit > node.size()) return Error.BadProgramHeader;

        // Permissions come from the segment, so .text lands read-execute and
        // .data read-write — the same W^X discipline the kernel uses.
        var flags: u64 = vmm.PRESENT | vmm.USER;
        if (ph.flags & PF_W != 0) flags |= vmm.WRITABLE;
        if (ph.flags & PF_X == 0) flags |= vmm.NO_EXECUTE;

        const start = std.mem.alignBackward(u64, ph.vaddr, vmm.PAGE_SIZE);
        const end = std.mem.alignForward(u64, memory_end, vmm.PAGE_SIZE);

        var page = start;
        while (page < end) : (page += vmm.PAGE_SIZE) {
            // A page may already be mapped when two segments share one.
            const existing = vmm.translate(pml4_phys, page);
            const phys = if (existing) |p| p else try vmm.allocAndMap(pml4_phys, page, flags);
            if (existing != null) try vmm.mapPage(pml4_phys, page, phys, flags | vmm.OWNED);

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
                try readExact(node, src_off, dest[dst_off .. dst_off + n]);
            }
        }

        if (end > brk) brk = end;
    }

    return .{ .entry = hdr.entry, .brk = brk };
}
