//! A disk that is a stretch of memory.
//!
//! The Arm port's first disk: the virtual machine loads the disk image into
//! memory before the kernel starts and says where it is. Reads and writes
//! are copies; writes are lost at power off. The real disk driver for Arm
//! machines (virtio-blk) is stage A3 of docs/design/015.

const block = @import("block.zig");

var base: [*]u8 = undefined;
var sectors: u64 = 0;
var context: u8 = 0;

fn read(_: *anyopaque, lba: u64, count: u32, buf: [*]u8) block.Error!void {
    if (lba + count > sectors) return block.Error.OutOfRange;
    const bytes = @as(usize, count) * block.SECTOR_SIZE;
    @memcpy(buf[0..bytes], base[lba * block.SECTOR_SIZE ..][0..bytes]);
}

fn write(_: *anyopaque, lba: u64, count: u32, buf: [*]const u8) block.Error!void {
    if (lba + count > sectors) return block.Error.OutOfRange;
    const bytes = @as(usize, count) * block.SECTOR_SIZE;
    @memcpy(base[lba * block.SECTOR_SIZE ..][0..bytes], buf[0..bytes]);
}

fn flush(_: *anyopaque) block.Error!void {}

/// `address` is a kernel address of `size` bytes holding the image.
pub fn init(address: u64, size: u64) ?*block.Device {
    if (size < block.SECTOR_SIZE) return null;
    base = @ptrFromInt(address);
    sectors = size / block.SECTOR_SIZE;
    const name = block.makeName("ram0");
    return block.register(.{
        .name = name.buf,
        .name_len = name.len,
        .ctx = &context,
        .ops = .{ .read = read, .write = write, .flush = flush },
        .sectors = sectors,
    });
}
