//! /data: the tmpfs volume kept on a data disk (docs/design/013).
//!
//! The data disk is a whole disk (not a partition) that starts with this
//! layout, in 4 KiB blocks:
//!
//!   block 0            superblock: "OrangeOS data v1", version 1, the slot
//!                      size in blocks, and a CRC-32 of those fields
//!   1 .. 1+n           slot 0: a header block, then the payload
//!   1+n .. 1+2n        slot 1
//!
//! A slot header holds a magic, a generation, the payload's length and
//! CRC-32, and a CRC-32 of the header itself. The payload is the volume as
//! tmpfs.saveLocked writes it.
//!
//! Saving writes the payload into the slot not holding the newest save,
//! flushes the disk's write cache, then writes that slot's header with the
//! next generation and flushes again. Loading takes the valid slot with the
//! highest generation. A save cut short by a crash or power loss therefore
//! leaves the previous save in force, and never a mixture of the two.
//!
//! The volume is saved when a program asks (fsync, fdatasync, syncfs,
//! sync) and every two seconds while it has unsaved changes.

const std = @import("std");
const block = @import("../../drivers/block/block.zig");
const tmpfs = @import("tmpfs.zig");
const pmm = @import("../../mm/pmm.zig");
const heap = @import("../../mm/heap.zig");
const sched = @import("../../sched/sched.zig");
const spinlock = @import("../../sync/spinlock.zig");
const console = @import("../../console.zig");

const BLOCK: usize = 4096;
const SECTORS: u32 = BLOCK / block.SECTOR_SIZE;
const SUPER_MAGIC = "OrangeOS data v1";
const SLOT_MAGIC = "ORDSLOT1";
const VERSION: u32 = 1;
const SAVE_INTERVAL_MS = 2000;

pub const Error = error{ NoSpace, OutOfMemory, IoError };

var device: ?*block.Device = null;
var slot_blocks: u64 = 0;
/// The newest save on disk (0: none yet) and the slot holding it.
var generation: u64 = 0;
var newest: usize = 0;
/// One save at a time.
var saving = std.atomic.Value(bool).init(false);

fn crc(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

fn slotBlock(slot: usize) u64 {
    return 1 + @as(u64, slot) * slot_blocks;
}

fn capacity() u64 {
    return (slot_blocks - 1) * BLOCK;
}

fn readBlock(d: *block.Device, index: u64, buf: *[BLOCK]u8) Error!void {
    d.read(index * SECTORS, SECTORS, buf) catch return Error.IoError;
}

fn writeBlock(d: *block.Device, index: u64, buf: *const [BLOCK]u8) Error!void {
    d.write(index * SECTORS, SECTORS, buf) catch return Error.IoError;
}

/// The write cache to disk; a device without a flush command writes
/// through (or cannot promise more), so that is not an error.
fn flush(d: *block.Device) Error!void {
    d.flush() catch |e| if (e != block.Error.NotSupported) return Error.IoError;
}

// ── Payload buffers ─────────────────────────────────────────────────────────

/// A payload in physical pages: saves are copied out under the tmpfs lock,
/// then written without it; loads are read and checked before parsing.
const Pages = struct {
    frames: []u64,
    len: u64,

    fn init(len: u64) Error!Pages {
        const count: usize = @intCast(@max((len + BLOCK - 1) / BLOCK, 1));
        const raw = heap.alloc(count * @sizeOf(u64)) catch return Error.OutOfMemory;
        const frames = @as([*]u64, @ptrCast(@alignCast(raw)))[0..count];
        for (frames, 0..) |*frame, i| {
            frame.* = pmm.allocPageZeroed() catch {
                for (frames[0..i]) |f| pmm.freePage(f);
                heap.free(raw);
                return Error.OutOfMemory;
            };
        }
        return .{ .frames = frames, .len = len };
    }

    fn deinit(self: *Pages) void {
        for (self.frames) |f| pmm.freePage(f);
        heap.free(@ptrCast(self.frames.ptr));
    }

    fn page(self: *const Pages, index: usize) *[BLOCK]u8 {
        return @ptrFromInt(pmm.physToVirt(self.frames[index]));
    }

    fn checksum(self: *const Pages) u32 {
        var hasher = std.hash.Crc32.init();
        var done: u64 = 0;
        for (0..self.frames.len) |i| {
            const chunk: usize = @intCast(@min(BLOCK, self.len - done));
            hasher.update(self.page(i)[0..chunk]);
            done += chunk;
        }
        return hasher.final();
    }
};

const Sink = struct {
    pages: *const Pages,
    at: u64 = 0,

    pub fn put(self: *Sink, bytes: []const u8) void {
        var done: usize = 0;
        while (done < bytes.len) {
            const within: usize = @intCast(self.at % BLOCK);
            const chunk = @min(BLOCK - within, bytes.len - done);
            @memcpy(self.pages.page(@intCast(self.at / BLOCK))[within .. within + chunk], bytes[done .. done + chunk]);
            done += chunk;
            self.at += chunk;
        }
    }
};

const Source = struct {
    pages: *const Pages,
    at: u64 = 0,

    pub fn get(self: *Source, buf: []u8) bool {
        if (buf.len > self.pages.len - self.at) return false;
        var done: usize = 0;
        while (done < buf.len) {
            const within: usize = @intCast(self.at % BLOCK);
            const chunk = @min(BLOCK - within, buf.len - done);
            @memcpy(buf[done .. done + chunk], self.pages.page(@intCast(self.at / BLOCK))[within .. within + chunk]);
            done += chunk;
            self.at += chunk;
        }
        return true;
    }
};

// ── Mounting ────────────────────────────────────────────────────────────────

const Header = struct { generation: u64, len: u64, payload_crc: u32 };

fn parseHeader(buf: *const [BLOCK]u8) ?Header {
    if (!std.mem.eql(u8, buf[0..8], SLOT_MAGIC)) return null;
    if (crc(buf[0..28]) != std.mem.readInt(u32, buf[28..32], .little)) return null;
    const header: Header = .{
        .generation = std.mem.readInt(u64, buf[8..16], .little),
        .len = std.mem.readInt(u64, buf[16..24], .little),
        .payload_crc = std.mem.readInt(u32, buf[24..28], .little),
    };
    if (header.generation == 0 or header.len == 0 or header.len > capacity()) return null;
    return header;
}

/// Find a data disk and load its newest valid save into /data. Without
/// one, /data stays a directory of the read-only root.
pub fn mount() void {
    const scratch = pmm.allocPageZeroed() catch return;
    defer pmm.freePage(scratch);
    const buf: *[BLOCK]u8 = @ptrFromInt(pmm.physToVirt(scratch));
    for (block.list()) |*d| {
        if (d.lba_offset != 0 or d.sector_size != block.SECTOR_SIZE) continue;
        if (d.sectors < 3 * SECTORS) continue;
        readBlock(d, 0, buf) catch continue;
        if (!std.mem.eql(u8, buf[0..16], SUPER_MAGIC)) continue;
        if (crc(buf[0..32]) != std.mem.readInt(u32, buf[32..36], .little) or
            std.mem.readInt(u32, buf[16..20], .little) != VERSION)
        {
            console.warn("data disk {s}: unknown or damaged superblock; not mounted", .{d.nameSlice()});
            continue;
        }
        const blocks = std.mem.readInt(u64, buf[24..32], .little);
        if (blocks < 2 or 1 + 2 * blocks > d.sectors / SECTORS) {
            console.warn("data disk {s}: slots do not fit the disk; not mounted", .{d.nameSlice()});
            continue;
        }
        device = d;
        slot_blocks = blocks;
        load(d, buf);
        return;
    }
}

fn load(d: *block.Device, buf: *[BLOCK]u8) void {
    var headers: [2]?Header = .{ null, null };
    for (0..2) |slot| {
        readBlock(d, slotBlock(slot), buf) catch continue;
        headers[slot] = parseHeader(buf);
    }
    {
        const state = spinlock.acquireIrqSave(&tmpfs.lock);
        defer spinlock.releaseIrqRestore(&tmpfs.lock, state);
        // Room for the payload's records as well as the pages themselves.
        tmpfs.data.quota_pages = capacity() / BLOCK * 7 / 8;
        tmpfs.data.persistent = true;
    }
    // Newest first; an unreadable or inconsistent save falls back to the
    // other slot.
    const order: [2]usize = if ((headers[1] orelse Header{ .generation = 0, .len = 0, .payload_crc = 0 }).generation >
        (headers[0] orelse Header{ .generation = 0, .len = 0, .payload_crc = 0 }).generation) .{ 1, 0 } else .{ 0, 1 };
    for (order) |slot| {
        const header = headers[slot] orelse continue;
        var pages = Pages.init(header.len) catch continue;
        defer pages.deinit();
        const read_ok = blk: {
            for (0..pages.frames.len) |i| readBlock(d, slotBlock(slot) + 1 + i, pages.page(i)) catch break :blk false;
            break :blk true;
        };
        if (!read_ok or pages.checksum() != header.payload_crc) {
            console.warn("data volume: save {d} in slot {d} is damaged; trying the other", .{ header.generation, slot });
            continue;
        }
        var source: Source = .{ .pages = &pages };
        const loaded = blk: {
            const state = spinlock.acquireIrqSave(&tmpfs.lock);
            defer spinlock.releaseIrqRestore(&tmpfs.lock, state);
            tmpfs.loadLocked(&tmpfs.data, &source) catch break :blk false;
            break :blk true;
        };
        if (!loaded) {
            console.warn("data volume: save {d} in slot {d} does not parse; trying the other", .{ header.generation, slot });
            continue;
        }
        generation = header.generation;
        newest = slot;
        console.print("[ ok ] data volume on {s}: save {d}, {d} KiB\n", .{ d.nameSlice(), generation, header.len / 1024 });
        return;
    }
    console.print("[ ok ] data volume on {s}: empty\n", .{d.nameSlice()});
}

// ── Saving ──────────────────────────────────────────────────────────────────

fn markDirty() void {
    const state = spinlock.acquireIrqSave(&tmpfs.lock);
    defer spinlock.releaseIrqRestore(&tmpfs.lock, state);
    tmpfs.data.dirty = true;
}

/// Write /data to its disk if it changed since the last save. Returns when
/// the save is on stable storage. Without a data disk there is nothing to
/// do. Call with interrupts enabled.
pub fn save() Error!void {
    const d = device orelse return;
    while (saving.cmpxchgWeak(false, true, .acquire, .monotonic) != null) sched.yield();
    defer saving.store(false, .release);

    var pages: Pages = undefined;
    {
        const state = spinlock.acquireIrqSave(&tmpfs.lock);
        defer spinlock.releaseIrqRestore(&tmpfs.lock, state);
        if (!tmpfs.needsSaveLocked(&tmpfs.data)) return;
        const size = tmpfs.savedSizeLocked(&tmpfs.data);
        if (size > capacity()) return Error.NoSpace;
        pages = try Pages.init(size);
        var sink: Sink = .{ .pages = &pages };
        tmpfs.saveLocked(&tmpfs.data, &sink);
    }
    defer pages.deinit();
    const target: usize = if (generation == 0) 0 else 1 - newest;
    writeSave(d, target, &pages) catch |e| {
        markDirty();
        return e;
    };
    generation += 1;
    newest = target;
}

fn writeSave(d: *block.Device, slot: usize, pages: *const Pages) Error!void {
    for (0..pages.frames.len) |i| try writeBlock(d, slotBlock(slot) + 1 + i, pages.page(i));
    try flush(d);
    const scratch = pmm.allocPageZeroed() catch return Error.OutOfMemory;
    defer pmm.freePage(scratch);
    const header: *[BLOCK]u8 = @ptrFromInt(pmm.physToVirt(scratch));
    @memcpy(header[0..8], SLOT_MAGIC);
    std.mem.writeInt(u64, header[8..16], generation + 1, .little);
    std.mem.writeInt(u64, header[16..24], pages.len, .little);
    std.mem.writeInt(u32, header[24..28], pages.checksum(), .little);
    std.mem.writeInt(u32, header[28..32], crc(header[0..28]), .little);
    try writeBlock(d, slotBlock(slot), header);
    try flush(d);
}

fn serviceThread(_: ?*anyopaque) void {
    while (true) {
        sched.sleepMs(SAVE_INTERVAL_MS);
        save() catch |e| console.warn("data volume: save failed: {s}", .{@errorName(e)});
    }
}

/// Periodic saves; after the scheduler is up and only with a data disk.
pub fn startService() void {
    if (device == null) return;
    _ = sched.spawn("data-save", serviceThread, null, .batch) catch {
        console.warn("data volume: could not start the save thread; only fsync saves", .{});
    };
}
