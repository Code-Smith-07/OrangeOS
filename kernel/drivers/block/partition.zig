//! GPT partition table parsing.
//!
//! Each partition is registered as its own block device with an LBA offset, so
//! a filesystem mounts a partition exactly the way it would mount a whole
//! disk and never has to think about the offset.
//!
//! MBR is not supported: Orange OS targets UEFI, and a protective MBR is all a
//! GPT disk carries anyway.

const std = @import("std");
const block = @import("block.zig");
const console = @import("../../console.zig");
const fmt = @import("../../lib/fmt.zig");

const GPT_SIGNATURE = "EFI PART";
const GPT_HEADER_LBA: u64 = 1;

const Header = extern struct {
    signature: [8]u8,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    entry_array_lba: u64,
    entry_count: u32,
    entry_size: u32,
    entry_array_crc32: u32,
};

const Entry = extern struct {
    type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    /// UTF-16LE, null padded.
    name: [72]u8,
};

fn guidIsZero(guid: [16]u8) bool {
    for (guid) |b| {
        if (b != 0) return false;
    }
    return true;
}

/// Well-known type GUIDs, little-endian as stored on disk.
const ESP_GUID = [16]u8{
    0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B,
};

fn typeName(guid: [16]u8) []const u8 {
    if (std.mem.eql(u8, &guid, &ESP_GUID)) return "EFI System";
    return "data";
}

/// Copy the UTF-16LE partition name into ASCII, best effort.
fn asciiName(src: [72]u8, dest: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < src.len and n < dest.len) : (i += 2) {
        const c = src[i];
        if (c == 0 and src[i + 1] == 0) break;
        dest[n] = if (c >= 0x20 and c < 0x7F) c else '?';
        n += 1;
    }
    return dest[0..n];
}

/// Scan `dev` for a GPT and register every partition found.
pub fn scan(dev: *block.Device) !usize {
    var sector: [512]u8 align(8) = undefined;

    dev.read(GPT_HEADER_LBA, 1, &sector) catch return 0;

    const hdr: *align(1) const Header = @ptrCast(&sector);
    if (!std.mem.eql(u8, hdr.signature[0..8], GPT_SIGNATURE)) return 0;
    if (hdr.entry_size < @sizeOf(Entry)) return 0;

    var found: usize = 0;
    const per_sector = block.SECTOR_SIZE / hdr.entry_size;
    if (per_sector == 0) return 0;

    var index: u32 = 0;
    var entry_buf: [512]u8 align(8) = undefined;

    while (index < hdr.entry_count and found < 8) : (index += 1) {
        const lba = hdr.entry_array_lba + index / per_sector;
        const offset = (index % per_sector) * hdr.entry_size;

        if (index % per_sector == 0) {
            dev.read(lba, 1, &entry_buf) catch break;
        }

        const e: *align(1) const Entry = @ptrCast(entry_buf[offset..].ptr);
        if (guidIsZero(e.type_guid)) continue;
        if (e.last_lba < e.first_lba) continue;

        var name_buf: [16]u8 = undefined;
        const pname = std.fmt.bufPrint(&name_buf, "{s}p{d}", .{ dev.nameSlice(), found + 1 }) catch continue;
        const n = block.makeName(pname);

        const sectors = e.last_lba - e.first_lba + 1;
        _ = block.register(.{
            .name = n.buf,
            .name_len = n.len,
            .ctx = dev.ctx,
            .ops = dev.ops,
            .sectors = sectors,
            .lba_offset = dev.lba_offset + e.first_lba,
        });

        var label: [40]u8 = undefined;
        var cap: [32]u8 = undefined;
        console.print("[ ok ] partition {s}: {s}, {s} (LBA {d}..{d}) \"{s}\"\n", .{
            pname,
            typeName(e.type_guid),
            fmt.humanBytes(&cap, sectors * block.SECTOR_SIZE),
            e.first_lba,
            e.last_lba,
            asciiName(e.name, &label),
        });

        found += 1;
    }

    return found;
}

/// Scan every registered whole-disk device.
pub fn scanAll() usize {
    var total: usize = 0;
    // Snapshot the count first: registering partitions extends the list, and
    // partitions must not themselves be re-scanned for partitions.
    const disks = block.list();
    const disk_count = disks.len;

    var i: usize = 0;
    while (i < disk_count) : (i += 1) {
        const dev = &block.list()[i];
        if (dev.lba_offset != 0) continue;
        total += scan(dev) catch 0;
    }
    return total;
}
