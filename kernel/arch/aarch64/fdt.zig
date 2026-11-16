//! Device tree reader.
//!
//! An Arm machine does not have fixed device addresses the way a PC has
//! "the serial port is at 0x3F8". The firmware (or QEMU) hands the kernel a
//! device tree: a packed, big-endian description of the memory, the
//! processors and every device with its address. This reads it without
//! allocating anything.
//!
//! Only what the kernel needs is understood: each node's name, its
//! `compatible` and `device_type` strings, its first `reg` address and size,
//! its `method` (PSCI) and its `interrupts`.

const std = @import("std");

const MAGIC: u32 = 0xD00D_FEED;
const BEGIN_NODE: u32 = 1;
const END_NODE: u32 = 2;
const PROP: u32 = 3;
const NOP: u32 = 4;
const END: u32 = 9;
const MAX_DEPTH = 16;

fn be32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}

/// A number made of `cells` 32-bit big-endian words.
fn cellsAt(bytes: []const u8, at: usize, cells: u32) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < cells) : (i += 1) value = (value << 32) | be32(bytes, at + i * 4);
    return value;
}

pub const Node = struct {
    name: []const u8 = "",
    depth: usize = 0,
    /// One or more names separated by zero bytes, most specific first.
    compatible: []const u8 = "",
    device_type: []const u8 = "",
    method: []const u8 = "",
    reg: []const u8 = "",
    interrupts: []const u8 = "",
    /// How the PARENT of this node says addresses and sizes are written.
    address_cells: u32 = 2,
    size_cells: u32 = 1,
    /// What this node says for its own children.
    child_address_cells: u32 = 2,
    child_size_cells: u32 = 1,

    pub fn is(self: *const Node, wanted: []const u8) bool {
        var it = std.mem.splitScalar(u8, self.compatible, 0);
        while (it.next()) |name| if (std.mem.eql(u8, name, wanted)) return true;
        return false;
    }

    /// The first address in `reg`.
    pub fn address(self: *const Node) ?u64 {
        if (self.reg.len < self.address_cells * 4) return null;
        return cellsAt(self.reg, 0, self.address_cells);
    }

    /// The size that goes with the first address.
    pub fn size(self: *const Node) ?u64 {
        const need = (self.address_cells + self.size_cells) * 4;
        if (self.size_cells == 0 or self.reg.len < need) return null;
        return cellsAt(self.reg, self.address_cells * 4, self.size_cells);
    }

    /// The n-th address/size pair of `reg` (the interrupt controller has two).
    pub fn addressAt(self: *const Node, n: usize) ?u64 {
        const pair = (self.address_cells + self.size_cells) * 4;
        if (self.reg.len < pair * n + self.address_cells * 4) return null;
        return cellsAt(self.reg, pair * n, self.address_cells);
    }
};

pub const Tree = struct {
    blob: []const u8,
    structs: usize,
    strings: usize,

    /// Returns null unless `start` begins a device tree.
    pub fn at(start: [*]const u8) ?Tree {
        const header = start[0..40];
        if (be32(header, 0) != MAGIC) return null;
        const total = be32(header, 4);
        if (total < 40 or total > 16 * 1024 * 1024) return null;
        return .{ .blob = start[0..total], .structs = be32(header, 8), .strings = be32(header, 12) };
    }

    pub fn nodes(self: *const Tree) Iterator {
        return .{ .tree = self, .at = self.structs };
    }

    /// The first node that names `compatible`.
    pub fn find(self: *const Tree, compatible: []const u8) ?Node {
        var it = self.nodes();
        while (it.next()) |node| if (node.is(compatible)) return node;
        return null;
    }

    /// The first node of a device type ("memory", "cpu").
    pub fn findType(self: *const Tree, device_type: []const u8) ?Node {
        var it = self.nodes();
        while (it.next()) |node| if (std.mem.eql(u8, node.device_type, device_type)) return node;
        return null;
    }

    pub fn count(self: *const Tree, device_type: []const u8) usize {
        var n: usize = 0;
        var it = self.nodes();
        while (it.next()) |node| {
            if (std.mem.eql(u8, node.device_type, device_type)) n += 1;
        }
        return n;
    }

    fn string(self: *const Tree, offset: u32) []const u8 {
        const from = self.strings + offset;
        if (from >= self.blob.len) return "";
        const rest = self.blob[from..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
    }
};

/// Yields every node once, when the node ends (so all its properties are
/// known). Children therefore come before their parent.
pub const Iterator = struct {
    tree: *const Tree,
    at: usize,
    stack: [MAX_DEPTH]Node = [_]Node{.{}} ** MAX_DEPTH,
    depth: usize = 0,
    done: bool = false,

    pub fn next(self: *Iterator) ?Node {
        const blob = self.tree.blob;
        while (!self.done and self.at + 4 <= blob.len) {
            const token = be32(blob, self.at);
            self.at += 4;
            switch (token) {
                BEGIN_NODE => {
                    const rest = blob[self.at..];
                    const len = std.mem.indexOfScalar(u8, rest, 0) orelse {
                        self.done = true;
                        return null;
                    };
                    self.at = std.mem.alignForward(usize, self.at + len + 1, 4);
                    if (self.depth >= MAX_DEPTH) {
                        self.done = true;
                        return null;
                    }
                    var node: Node = .{ .name = rest[0..len], .depth = self.depth };
                    if (self.depth > 0) {
                        const parent = &self.stack[self.depth - 1];
                        node.address_cells = parent.child_address_cells;
                        node.size_cells = parent.child_size_cells;
                    }
                    self.stack[self.depth] = node;
                    self.depth += 1;
                },
                END_NODE => {
                    if (self.depth == 0) {
                        self.done = true;
                        return null;
                    }
                    self.depth -= 1;
                    return self.stack[self.depth];
                },
                PROP => {
                    if (self.at + 8 > blob.len) break;
                    const len = be32(blob, self.at);
                    const name = self.tree.string(be32(blob, self.at + 4));
                    const from = self.at + 8;
                    if (from + len > blob.len) break;
                    const value = blob[from .. from + len];
                    self.at = std.mem.alignForward(usize, from + len, 4);
                    if (self.depth == 0) continue;
                    const node = &self.stack[self.depth - 1];
                    if (std.mem.eql(u8, name, "compatible")) {
                        node.compatible = value;
                    } else if (std.mem.eql(u8, name, "device_type")) {
                        node.device_type = text(value);
                    } else if (std.mem.eql(u8, name, "method")) {
                        node.method = text(value);
                    } else if (std.mem.eql(u8, name, "reg")) {
                        node.reg = value;
                    } else if (std.mem.eql(u8, name, "interrupts")) {
                        node.interrupts = value;
                    } else if (std.mem.eql(u8, name, "#address-cells") and len == 4) {
                        node.child_address_cells = be32(value, 0);
                    } else if (std.mem.eql(u8, name, "#size-cells") and len == 4) {
                        node.child_size_cells = be32(value, 0);
                    }
                },
                NOP => {},
                else => break, // END, or something this reader does not know
            }
        }
        self.done = true;
        return null;
    }

    fn text(value: []const u8) []const u8 {
        return value[0 .. std.mem.indexOfScalar(u8, value, 0) orelse value.len];
    }
};

// ── Tests (run on the build machine) ────────────────────────────────────────

const Builder = struct {
    structs: std.ArrayList(u8),
    strings: std.ArrayList(u8),

    fn word(self: *Builder, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        try self.structs.appendSlice(&b);
    }
    fn begin(self: *Builder, name: []const u8) !void {
        try self.word(BEGIN_NODE);
        try self.structs.appendSlice(name);
        try self.structs.append(0);
        while (self.structs.items.len % 4 != 0) try self.structs.append(0);
    }
    fn end(self: *Builder) !void {
        try self.word(END_NODE);
    }
    fn prop(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.word(PROP);
        try self.word(@intCast(value.len));
        try self.word(@intCast(self.strings.items.len));
        try self.strings.appendSlice(name);
        try self.strings.append(0);
        try self.structs.appendSlice(value);
        while (self.structs.items.len % 4 != 0) try self.structs.append(0);
    }
    fn cells(self: *Builder, name: []const u8, values: []const u32) !void {
        var buf: [64]u8 = undefined;
        for (values, 0..) |v, i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], v, .big);
        try self.prop(name, buf[0 .. values.len * 4]);
    }
    fn finish(self: *Builder, out: *std.ArrayList(u8)) !void {
        try self.word(END);
        var header: [40]u8 = [_]u8{0} ** 40;
        const total: u32 = @intCast(40 + self.structs.items.len + self.strings.items.len);
        std.mem.writeInt(u32, header[0..4], MAGIC, .big);
        std.mem.writeInt(u32, header[4..8], total, .big);
        std.mem.writeInt(u32, header[8..12], 40, .big);
        std.mem.writeInt(u32, header[12..16], @intCast(40 + self.structs.items.len), .big);
        try out.appendSlice(&header);
        try out.appendSlice(self.structs.items);
        try out.appendSlice(self.strings.items);
    }
};

fn sample(out: *std.ArrayList(u8)) !void {
    const a = std.testing.allocator;
    var b: Builder = .{ .structs = std.ArrayList(u8).init(a), .strings = std.ArrayList(u8).init(a) };
    defer b.structs.deinit();
    defer b.strings.deinit();
    try b.begin("");
    try b.cells("#address-cells", &.{2});
    try b.cells("#size-cells", &.{2});
    try b.begin("memory@40000000");
    try b.cells("reg", &.{ 0, 0x4000_0000, 1, 0 }); // 4 GB at 1 GB
    try b.prop("device_type", "memory\x00");
    try b.end();
    try b.begin("cpus");
    try b.cells("#address-cells", &.{1});
    try b.cells("#size-cells", &.{0});
    for ([_]u32{ 0, 1, 2 }) |n| {
        try b.begin("cpu");
        try b.prop("device_type", "cpu\x00");
        try b.cells("reg", &.{n});
        try b.end();
    }
    try b.end();
    try b.begin("pl011@9000000");
    // Properties in the order QEMU writes them: reg after compatible is not
    // guaranteed, so the reader must not depend on it.
    try b.cells("reg", &.{ 0, 0x0900_0000, 0, 0x1000 });
    try b.prop("compatible", "arm,pl011\x00arm,primecell\x00");
    try b.end();
    try b.begin("intc@8000000");
    try b.prop("compatible", "arm,gic-v3\x00");
    try b.cells("reg", &.{ 0, 0x0800_0000, 0, 0x10000, 0, 0x080A_0000, 0, 0xF60000 });
    try b.end();
    try b.begin("psci");
    try b.prop("method", "hvc\x00");
    try b.prop("compatible", "arm,psci-1.0\x00arm,psci-0.2\x00arm,psci\x00");
    try b.end();
    try b.end();
    try b.finish(out);
}

test "a blob that is not a device tree is refused" {
    const junk = [_]u8{0} ** 64;
    try std.testing.expect(Tree.at(&junk) == null);
}

test "memory, processors and devices are found whatever the property order" {
    var blob = std.ArrayList(u8).init(std.testing.allocator);
    defer blob.deinit();
    try sample(&blob);
    const tree = Tree.at(blob.items.ptr).?;

    const memory = tree.findType("memory").?;
    try std.testing.expectEqual(@as(u64, 0x4000_0000), memory.address().?);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), memory.size().?);

    try std.testing.expectEqual(@as(usize, 3), tree.count("cpu"));

    const uart = tree.find("arm,pl011").?;
    try std.testing.expectEqual(@as(u64, 0x0900_0000), uart.address().?);
    try std.testing.expect(uart.is("arm,primecell"));
    try std.testing.expect(!uart.is("arm"));

    const gic = tree.find("arm,gic-v3").?;
    try std.testing.expectEqual(@as(u64, 0x0800_0000), gic.addressAt(0).?);
    try std.testing.expectEqual(@as(u64, 0x080A_0000), gic.addressAt(1).?);
    try std.testing.expect(gic.addressAt(2) == null);

    try std.testing.expectEqualStrings("hvc", tree.find("arm,psci-0.2").?.method);
    try std.testing.expect(tree.find("arm,gic-v2") == null);
}

test "processor numbers use the one-cell addresses their parent declares" {
    var blob = std.ArrayList(u8).init(std.testing.allocator);
    defer blob.deinit();
    try sample(&blob);
    const tree = Tree.at(blob.items.ptr).?;
    var seen: [3]bool = .{ false, false, false };
    var it = tree.nodes();
    while (it.next()) |node| {
        if (!std.mem.eql(u8, node.device_type, "cpu")) continue;
        seen[@intCast(node.address().?)] = true;
        try std.testing.expect(node.size() == null);
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2]);
}

test "a truncated tree ends the walk instead of reading past the end" {
    var blob = std.ArrayList(u8).init(std.testing.allocator);
    defer blob.deinit();
    try sample(&blob);
    var tree = Tree.at(blob.items.ptr).?;
    tree.blob = tree.blob[0 .. tree.structs + 30];
    var it = tree.nodes();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expect(n < 8);
}
