//! Opt-in QEMU legacy virtio-console, one named port, polling, bounded queues.
//! No direct Mac hardware access. DMA memory is never freed before device reset.
const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const io = @import("../../arch/x86_64/io.zig");
const pmm = @import("../../mm/pmm.zig");
const sync = @import("../../sync/spinlock.zig");
const console = @import("../../console.zig");

const MAX_QUEUE = 256;
const PACKET = 512;
const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const Used = extern struct { id: u32, len: u32 };
const Error = error{ InvalidDevice, InvalidQueue, OutOfMemory };
var lock: sync.SpinLock = .{};
var base: u16 = 0;
var present = false;
var named = false;
var host_open = false;
var generation: u32 = 1;
var credential: [64]u8 = undefined;
// QEMU reserves port 0 for virtconsole; named serial port 1 uses queues 4/5.
var queues: [6]Queue = [_]Queue{.{}} ** 6;

fn fence() void {
    asm volatile ("mfence" ::: "memory");
}
const Queue = struct {
    phys: u64 = 0,
    buffers: u64 = 0,
    count: u16 = 0,
    index: u16 = 0,
    used_offset: usize = 0,
    last: u16 = 0,
    busy: [MAX_QUEUE]bool = [_]bool{false} ** MAX_QUEUE,
    held: ?u16 = null,
    held_len: usize = 0,
    held_pos: usize = 0,
    fn desc(self: *Queue) [*]volatile Desc {
        return @ptrFromInt(pmm.hhdmBase() + self.phys);
    }
    fn avail(self: *Queue) [*]volatile u16 {
        return @ptrFromInt(pmm.hhdmBase() + self.phys + 16 * @as(u64, self.count));
    }
    fn usedIndex(self: *Queue) *volatile u16 {
        return @ptrFromInt(pmm.hhdmBase() + self.phys + self.used_offset + 2);
    }
    fn used(self: *Queue) [*]volatile Used {
        return @ptrFromInt(pmm.hhdmBase() + self.phys + self.used_offset + 4);
    }
    fn data(self: *Queue, id: u16) []u8 {
        const ptr: [*]u8 = @ptrFromInt(pmm.hhdmBase() + self.buffers + @as(u64, id) * PACKET);
        return ptr[0..PACKET];
    }
    fn init(self: *Queue, index: u16) Error!void {
        io.outw(base + 14, index);
        const count = io.inw(base + 12);
        if (count == 0 or count > MAX_QUEUE or count & (count - 1) != 0 or io.inl(base + 8) != 0) return error.InvalidQueue;
        self.index = index;
        self.count = count;
        self.used_offset = std.mem.alignForward(usize, 16 * @as(usize, count) + 6 + 2 * @as(usize, count), 4096);
        self.phys = pmm.allocOrderZeroed(2) catch return error.OutOfMemory;
        self.buffers = pmm.allocOrderZeroed(5) catch return error.OutOfMemory;
        if (self.phys >> 12 > std.math.maxInt(u32)) return error.InvalidQueue;
        self.avail()[0] = 1; // NO_INTERRUPT: this initial driver polls.
        for (0..count) |i| self.desc()[i] = .{ .addr = self.buffers + i * PACKET, .len = PACKET, .flags = if (index % 2 == 0) 2 else 0, .next = 0 };
        fence();
        io.outl(base + 8, @intCast(self.phys >> 12));
        if (index % 2 == 0) for (0..count) |i| self.publish(@intCast(i));
    }
    fn publish(self: *Queue, id: u16) void {
        self.busy[id] = true;
        const a = self.avail();
        const index = a[1];
        a[2 + index % self.count] = id;
        fence();
        a[1] = index +% 1;
        fence();
    }
    fn pop(self: *Queue) Error!?Used {
        const next = self.usedIndex().*;
        if (next -% self.last > self.count) return error.InvalidQueue;
        if (next == self.last) return null;
        fence();
        const entry = self.used()[self.last % self.count];
        if (entry.id >= self.count or entry.len > PACKET or !self.busy[entry.id]) return error.InvalidQueue;
        self.last +%= 1;
        self.busy[entry.id] = false;
        return entry;
    }
    fn send(self: *Queue, bytes: []const u8) Error!bool {
        while (try self.pop()) |_| {}
        for (0..self.count) |i| {
            if (self.busy[i]) continue;
            @memcpy(self.data(@intCast(i))[0..bytes.len], bytes);
            self.desc()[i].len = @intCast(bytes.len);
            self.publish(@intCast(i));
            io.outw(base + 16, self.index);
            return true;
        }
        return false;
    }
    fn receive(self: *Queue, out: []u8) Error!usize {
        if (self.held == null) {
            const item = (try self.pop()) orelse return 0;
            self.held = @intCast(item.id);
            self.held_len = item.len;
            self.held_pos = 0;
        }
        const id = self.held.?;
        const n = @min(out.len, self.held_len - self.held_pos);
        @memcpy(out[0..n], self.data(id)[self.held_pos..][0..n]);
        self.held_pos += n;
        if (self.held_pos == self.held_len) {
            self.held = null;
            self.publish(id);
            io.outw(base + 16, self.index);
        }
        return n;
    }
};

// QEMU fw_cfg file directory is big endian; no credential logging. The private
// launch file is not part of the ISO or source. No file means no bridge startup.
fn loadCredential() bool {
    io.outw(0x510, 0);
    var signature: [4]u8 = undefined;
    for (&signature) |*b| b.* = io.inb(0x511);
    if (!std.mem.eql(u8, &signature, "QEMU")) return false;
    io.outw(0x510, 0x19);
    var count_bytes: [4]u8 = undefined;
    for (&count_bytes) |*b| b.* = io.inb(0x511);
    const count = std.mem.readInt(u32, &count_bytes, .big);
    if (count > 128) return false;
    for (0..count) |_| {
        var entry: [64]u8 = undefined;
        for (&entry) |*b| b.* = io.inb(0x511);
        const name = std.mem.sliceTo(entry[8..64], 0);
        if (!std.mem.eql(u8, name, "opt/orange/session")) continue;
        if (std.mem.readInt(u32, entry[0..4], .big) != 64) return false;
        io.outw(0x510, std.mem.readInt(u16, entry[4..6], .big));
        for (&credential) |*b| b.* = io.inb(0x511);
        for (credential) |b| if (!((b >= '0' and b <= '9') or (b >= 'a' and b <= 'f'))) return false;
        return true;
    }
    return false;
}

fn control(event: u16, value: u16) Error!void {
    var message = [_]u8{0} ** 8;
    std.mem.writeInt(u32, message[0..4], if (event == 0) 0 else 1, .little);
    std.mem.writeInt(u16, message[4..6], event, .little);
    std.mem.writeInt(u16, message[6..8], value, .little);
    if (!try queues[3].send(&message)) return error.InvalidQueue;
}

fn fail() void {
    if (base != 0) io.outb(base + 18, 0);
    present = false;
    host_open = false;
    named = false;
    generation +%= 1;
    // Retain DMA pages until a future explicit reset/reinit lifecycle. They
    // are bounded once per boot, never repeatedly allocated by a guest caller.
}

pub fn init() void {
    const dev = pci.findByVendor(0x1AF4, 0x1003) orelse return;
    if (!loadCredential()) return;
    const raw = dev.read32(pci.REG_BAR0);
    if (raw & 1 == 0 or raw & 0xFFFFFFFC > 0xFFE0) return;
    base = @intCast(raw & 0xFFFC);
    if (base == 0) return;
    dev.write16(pci.REG_COMMAND, dev.read16(pci.REG_COMMAND) | pci.CMD_IO_SPACE | pci.CMD_BUS_MASTER | pci.CMD_INTERRUPT_DISABLE);
    io.outb(base + 18, 0);
    io.outb(base + 18, 1);
    io.outb(base + 18, 3);
    if (io.inl(base) & 2 == 0) {
        fail();
        return;
    }
    io.outl(base + 4, 2); // VIRTIO_CONSOLE_F_MULTIPORT only.
    for (&queues, 0..) |*q, i| q.init(@intCast(i)) catch {
        fail();
        return;
    };
    io.outb(base + 18, 7); // DRIVER_OK (legacy negotiation)
    control(0, 1) catch {
        fail();
        return;
    }; // DEVICE_READY
    present = true;
    console.ok("host bridge: virtio-serial queues ready (read-only prototype)", .{});
}

fn poll() void {
    if (!present) return;
    var message: [PACKET]u8 = undefined;
    for (0..64) |_| {
        const n = queues[2].receive(&message) catch {
            fail();
            return;
        };
        if (n == 0) break;
        if (n < 8) {
            fail();
            return;
        }
        const id = std.mem.readInt(u32, message[0..4], .little);
        const event = std.mem.readInt(u16, message[4..6], .little);
        const value = std.mem.readInt(u16, message[6..8], .little);
        if (id != 1) continue; // Only the explicitly configured named port.
        switch (event) {
            1 => control(3, 1) catch {
                fail();
                return;
            }, // PORT_READY
            2 => {
                fail();
                return;
            },
            6 => {
                const open = value == 1;
                if (host_open != open) generation +%= 1;
                host_open = open;
            },
            7 => {
                named = std.mem.eql(u8, std.mem.sliceTo(message[8..n], 0), "org.orange.host");
                control(6, @intFromBool(named)) catch {
                    fail();
                    return;
                };
            },
            else => {},
        }
    }
}

/// Serialized under IRQ-safe lock. Nonblocking; max 512 bytes per call.
pub fn operation(op: u64, bytes: []u8) i64 {
    const state = sync.acquireIrqSave(&lock);
    defer sync.releaseIrqRestore(&lock, state);
    poll();
    if (!present) return -19;
    if (op == 2) return (@as(i64, generation) << 8) | 1 | (if (named and host_open) @as(i64, 2) else 0);
    if (op == 3) {
        if (bytes.len != 64) return -22;
        @memcpy(bytes, &credential);
        return 64;
    }
    if (!named or !host_open) return -11;
    if (bytes.len == 0 or bytes.len > PACKET) return -22;
    if (op == 0) return @intCast(queues[4].receive(bytes) catch {
        fail();
        return -5;
    });
    if (op == 1) return if (queues[5].send(bytes) catch {
        fail();
        return -5;
    }) @intCast(bytes.len) else -11;
    return -22;
}
