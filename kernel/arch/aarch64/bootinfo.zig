//! What the boot loader tells the kernel, on Arm64.
//!
//! The x86 kernel is started by Limine, which fills in a memory map, the
//! direct-map offset and the kernel's physical address. This Arm kernel is
//! started directly by the virtual machine with only a device tree, so the
//! same answers are worked out here and offered under the same names. The
//! shared memory code cannot tell the difference.

const std = @import("std");
const cpu = @import("cpu.zig");
const fdt = @import("fdt.zig");
const limine = @import("../../boot/limine_req.zig");

pub const MemmapType = limine.MemmapType;
pub const MemmapEntry = limine.MemmapEntry;
pub const MemmapResponse = limine.MemmapResponse;
pub const ExecutableAddressResponse = limine.ExecutableAddressResponse;
pub const FramebufferResponse = limine.FramebufferResponse;
pub const BootloaderInfoResponse = limine.BootloaderInfoResponse;
pub const MEMORY_MODEL_RGB = limine.MEMORY_MODEL_RGB;

extern const __kernel_start: u8;
extern const __kernel_end: u8;

const MAX_ENTRIES = 8;
var entries: [MAX_ENTRIES]MemmapEntry = undefined;
var entry_pointers: [MAX_ENTRIES]*MemmapEntry = undefined;
var memmap_response: MemmapResponse = .{ .revision = 0, .entry_count = 0, .entries = &entry_pointers };
var executable: ExecutableAddressResponse = .{ .revision = 0, .physical_base = 0, .virtual_base = 0 };
var ready = false;

/// A device the kernel talks to through memory, from the device tree.
pub const Region = struct { base: u64 = 0, size: u64 = 0 };
pub const MAX_REGIONS = 8;
var regions: [MAX_REGIONS]Region = [_]Region{.{}} ** MAX_REGIONS;
var region_count: usize = 0;

pub var uart: ?u64 = null;
/// The serial port's interrupt on the GIC, if the tree names one.
pub var uart_interrupt: ?u32 = null;
pub var gic_distributor: ?u64 = null;
pub var gic_redistributors: ?u64 = null;
pub var rtc: ?u64 = null;
pub var virtio_base: ?u64 = null;
pub var virtio_count: usize = 0;
pub var memory_bytes: u64 = 0;
pub var psci_uses_smc = false;
/// A disk image the virtual machine put in memory (bootargs
/// "ramdisk=ADDRESS,SIZE"), if any.
pub var ramdisk: Region = .{};
/// Hardware numbers of the processors, in device tree order.
pub var cpu_ids: [cpu.MAX_CPUS]u64 = [_]u64{0} ** cpu.MAX_CPUS;
pub var cpu_count: usize = 0;

fn add(base: u64, length: u64, kind: MemmapType) void {
    if (length == 0 or memmap_response.entry_count >= MAX_ENTRIES) return;
    const i = memmap_response.entry_count;
    entries[i] = .{ .base = base, .length = length, .type = kind };
    entry_pointers[i] = &entries[i];
    memmap_response.entry_count += 1;
}

fn device(node: fdt.Node, slot: *?u64) void {
    const base = node.address() orelse return;
    slot.* = base;
    addRegion(base, node.size() orelse 0x1000);
}

fn addRegion(base: u64, size: u64) void {
    if (region_count >= MAX_REGIONS) return;
    const from = std.mem.alignBackward(u64, base, 4096);
    regions[region_count] = .{ .base = from, .size = std.mem.alignForward(u64, base + size, 4096) - from };
    region_count += 1;
}

/// A device's first interrupt as a GIC number. The tree writes three cells:
/// kind (0 shared, 1 private), number, trigger.
fn sharedInterrupt(node: fdt.Node) ?u32 {
    if (node.interrupts.len < 12) return null;
    const kind = std.mem.readInt(u32, node.interrupts[0..4], .big);
    const number = std.mem.readInt(u32, node.interrupts[4..8], .big);
    return if (kind == 0) 32 + number else 16 + number;
}

fn parseNumber(text: []const u8) ?u64 {
    const hex = std.mem.startsWith(u8, text, "0x");
    return std.fmt.parseInt(u64, if (hex) text[2..] else text, if (hex) 16 else 10) catch null;
}

fn parseBootArgs(args: []const u8) void {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, "ramdisk=")) continue;
        var parts = std.mem.splitScalar(u8, word["ramdisk=".len..], ',');
        const base = parseNumber(parts.next() orelse continue) orelse continue;
        const size = parseNumber(parts.next() orelse continue) orelse continue;
        ramdisk = .{ .base = base, .size = size };
    }
}

/// Read the device tree and work out the memory map. False if the tree
/// has no memory in it.
pub fn init(tree: *const fdt.Tree) bool {
    var ram: Region = .{};
    var first_virtio: u64 = ~@as(u64, 0);
    var it = tree.nodes();
    while (it.next()) |node| {
        if (std.mem.eql(u8, node.device_type, "memory") and ram.size == 0) {
            ram = .{ .base = node.address() orelse 0, .size = node.size() orelse 0 };
        } else if (std.mem.eql(u8, node.device_type, "cpu")) {
            if (cpu_count < cpu.MAX_CPUS) {
                cpu_ids[cpu_count] = node.address() orelse cpu_count;
                cpu_count += 1;
            }
        } else if (node.is("arm,pl011")) {
            device(node, &uart);
            uart_interrupt = sharedInterrupt(node);
        } else if (node.is("arm,pl031")) {
            device(node, &rtc);
        } else if (node.is("arm,gic-v3")) {
            gic_distributor = node.addressAt(0);
            gic_redistributors = node.addressAt(1);
            if (gic_distributor) |base| addRegion(base, 0x10000);
            // Two 64 KB frames for each processor.
            if (gic_redistributors) |base| addRegion(base, 0x20000 * cpu.MAX_CPUS);
        } else if (node.is("virtio,mmio")) {
            if (node.address()) |base| {
                first_virtio = @min(first_virtio, base);
                virtio_count += 1;
            }
        } else if (node.is("arm,psci-0.2") or node.is("arm,psci-1.0")) {
            psci_uses_smc = std.mem.eql(u8, node.method, "smc");
        } else if (std.mem.eql(u8, node.name, "chosen")) {
            parseBootArgs(node.bootargs);
        }
    }
    if (ram.size == 0) return false;
    if (virtio_count > 0) {
        virtio_base = first_virtio;
        addRegion(first_virtio, virtio_count * 0x200);
    }
    memory_bytes = ram.size;

    // The memory map: the start of memory up to the end of the kernel is
    // taken (device tree, then the kernel image); so is a ramdisk; the rest
    // is free.
    const kernel_end = std.mem.alignForward(u64, cpu.phys(@intFromPtr(&__kernel_end)), 0x20_0000);
    const ram_end = ram.base + ram.size;
    add(ram.base, kernel_end - ram.base, .executable_and_modules);
    if (ramdisk.size != 0 and ramdisk.base >= kernel_end and ramdisk.base + ramdisk.size <= ram_end) {
        const disk_from = std.mem.alignBackward(u64, ramdisk.base, 4096);
        const disk_to = std.mem.alignForward(u64, ramdisk.base + ramdisk.size, 4096);
        add(kernel_end, disk_from - kernel_end, .usable);
        add(disk_from, disk_to - disk_from, .executable_and_modules);
        add(disk_to, ram_end - disk_to, .usable);
    } else {
        ramdisk = .{};
        add(kernel_end, ram_end - kernel_end, .usable);
    }

    executable = .{
        .revision = 0,
        .physical_base = cpu.phys(@intFromPtr(&__kernel_start)),
        .virtual_base = @intFromPtr(&__kernel_start),
    };
    ready = true;
    return true;
}

/// The devices that must stay reachable when the kernel switches to its
/// own page tables.
pub fn deviceRegions() []const Region {
    return regions[0..region_count];
}

// ── The same questions the x86 kernel asks Limine ──────────────────────────

pub fn baseRevisionSupported() bool {
    return true;
}
pub fn bootloaderInfo() ?*BootloaderInfoResponse {
    return null;
}
pub fn framebuffers() ?*FramebufferResponse {
    return null;
}
pub fn memmap() ?*MemmapResponse {
    return if (ready) &memmap_response else null;
}
pub fn executableAddress() ?*ExecutableAddressResponse {
    return if (ready) &executable else null;
}
pub fn rsdp() ?u64 {
    return null;
}
pub fn hhdmOffset() ?u64 {
    return cpu.HHDM;
}
