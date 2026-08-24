//! Block device abstraction.
//!
//! Everything above this layer — partitions, the VFS, filesystems — works in
//! 512-byte logical blocks and never learns whether the storage underneath is
//! SATA, NVMe, or virtio.

const std = @import("std");

pub const SECTOR_SIZE: usize = 512;

pub const Error = error{
    IoError,
    OutOfRange,
    NoDevice,
    Timeout,
    NotSupported,
};

pub const Ops = struct {
    read: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: [*]u8) Error!void,
    write: *const fn (ctx: *anyopaque, lba: u64, count: u32, buf: [*]const u8) Error!void,
};

pub const Device = struct {
    name: [16]u8,
    name_len: usize,
    ctx: *anyopaque,
    ops: Ops,
    /// Total addressable sectors.
    sectors: u64,
    sector_size: usize = SECTOR_SIZE,
    /// Offset applied to every request, so a partition can be a Device.
    lba_offset: u64 = 0,

    pub fn nameSlice(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn read(self: *const Device, lba: u64, count: u32, buf: [*]u8) Error!void {
        if (lba + count > self.sectors) return Error.OutOfRange;
        return self.ops.read(self.ctx, self.lba_offset + lba, count, buf);
    }

    pub fn write(self: *const Device, lba: u64, count: u32, buf: [*]const u8) Error!void {
        if (lba + count > self.sectors) return Error.OutOfRange;
        return self.ops.write(self.ctx, self.lba_offset + lba, count, buf);
    }

    pub fn byteCapacity(self: *const Device) u64 {
        return self.sectors * self.sector_size;
    }
};

pub const MAX_DEVICES = 8;
var devices: [MAX_DEVICES]Device = undefined;
var device_count: usize = 0;

pub fn register(dev: Device) ?*Device {
    if (device_count >= MAX_DEVICES) return null;
    devices[device_count] = dev;
    device_count += 1;
    return &devices[device_count - 1];
}

pub fn list() []Device {
    return devices[0..device_count];
}

pub fn find(name: []const u8) ?*Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (std.mem.eql(u8, devices[i].nameSlice(), name)) return &devices[i];
    }
    return null;
}

pub fn makeName(name: []const u8) struct { buf: [16]u8, len: usize } {
    var buf: [16]u8 = undefined;
    const n = @min(name.len, 16);
    @memcpy(buf[0..n], name[0..n]);
    return .{ .buf = buf, .len = n };
}
