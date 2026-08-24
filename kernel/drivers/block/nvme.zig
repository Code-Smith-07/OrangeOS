//! NVMe.
//!
//! Where AHCI is a SATA controller with a command list, NVMe is a queue pair
//! protocol: software writes 64-byte commands into a submission queue, rings a
//! doorbell, and the controller posts 16-byte completions into a completion
//! queue. Which completions are new is tracked by a *phase bit* that flips
//! every time the controller wraps — the same idea as xHCI's cycle bit, and
//! the same failure mode if it is wrong: the driver waits forever for a
//! completion that is already sitting in front of it.
//!
//! Data buffers are described by PRPs, physical region pages. PRP1 may start
//! anywhere within a page; every page after the first must be page-aligned,
//! which is why transfers here go through an aligned bounce buffer rather than
//! pointing at whatever the caller supplied.
//!
//! This matters for real hardware far more than AHCI does: essentially every
//! machine built since about 2018 boots from NVMe.

const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const block = @import("block.zig");
const console = @import("../../console.zig");
const tsc = @import("../../time/tsc.zig");

// Controller registers.
const REG_CAP: usize = 0x00;
const REG_VS: usize = 0x08;
const REG_CC: usize = 0x14;
const REG_CSTS: usize = 0x1C;
const REG_AQA: usize = 0x24;
const REG_ASQ: usize = 0x28;
const REG_ACQ: usize = 0x30;

const CC_EN: u32 = 1 << 0;
const CSTS_RDY: u32 = 1 << 0;
const CSTS_CFS: u32 = 1 << 1;

// Admin opcodes.
const ADMIN_CREATE_SQ: u8 = 0x01;
const ADMIN_CREATE_CQ: u8 = 0x05;
const ADMIN_IDENTIFY: u8 = 0x06;

// NVM opcodes.
const NVM_WRITE: u8 = 0x01;
const NVM_READ: u8 = 0x02;

const QUEUE_DEPTH: u16 = 32;
const IO_QUEUE_ID: u16 = 1;

/// Bounce buffer size, in pages. Two pages is the largest transfer describable
/// with PRP1 and PRP2 alone, which avoids needing a PRP list.
const BOUNCE_PAGES: usize = 2;

pub const Error = error{
    NoDevice,
    Timeout,
    OutOfMemory,
    InvalidOrder,
    ControllerFault,
    NoNamespace,
} || vmm.Error;

/// 64-byte submission queue entry.
///
/// The offsets are fixed by the specification and are checked below, because
/// getting one wrong does not produce an error: the controller executes the
/// command it was given, reports success, and DMAs to whatever address landed
/// in the PRP1 slot.
const SqEntry = extern struct {
    opcode: u8, // CDW0
    flags: u8,
    command_id: u16,
    nsid: u32, // CDW1
    reserved: u64, // CDW2-3
    metadata: u64, // CDW4-5, MPTR
    prp1: u64, // CDW6-7
    prp2: u64, // CDW8-9
    cdw10: u32,
    cdw11: u32,
    cdw12: u32,
    cdw13: u32,
    cdw14: u32,
    cdw15: u32,
};

comptime {
    if (@sizeOf(SqEntry) != 64) @compileError("NVMe SQ entry must be 64 bytes");
    if (@offsetOf(SqEntry, "nsid") != 4) @compileError("NSID must be at CDW1");
    if (@offsetOf(SqEntry, "metadata") != 16) @compileError("MPTR must be at CDW4");
    if (@offsetOf(SqEntry, "prp1") != 24) @compileError("PRP1 must be at CDW6");
    if (@offsetOf(SqEntry, "prp2") != 32) @compileError("PRP2 must be at CDW8");
    if (@offsetOf(SqEntry, "cdw10") != 40) @compileError("CDW10 must be at offset 40");
}

/// 16-byte completion queue entry.
const CqEntry = extern struct {
    result: u32,
    reserved: u32,
    sq_head: u16,
    sq_id: u16,
    command_id: u16,
    status: u16,
};

const Queue = struct {
    sq: [*]volatile SqEntry,
    sq_phys: u64,
    cq: [*]volatile CqEntry,
    cq_phys: u64,
    sq_tail: u16 = 0,
    cq_head: u16 = 0,
    /// Flips each time the completion queue wraps. A completion whose phase
    /// does not match is one the controller has not written yet.
    phase: u16 = 1,
    id: u16,
};

var mmio: u64 = 0;
var doorbell_stride: usize = 0;
var present: bool = false;
var next_command_id: u16 = 1;

var admin: Queue = undefined;
var io: Queue = undefined;

var namespace_id: u32 = 1;
var namespace_blocks: u64 = 0;
var namespace_block_size: usize = 512;

var bounce_phys: u64 = 0;
var bounce_virt: u64 = 0;

inline fn r32(o: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(mmio + o)).*;
}
inline fn w32(o: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(mmio + o)).* = v;
}
inline fn r64(o: usize) u64 {
    return @as(*volatile u64, @ptrFromInt(mmio + o)).*;
}
inline fn w64(o: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(mmio + o)).* = v;
}

/// Doorbell registers start at 0x1000 and are spaced by a stride the
/// controller advertises. Submission and completion doorbells alternate.
inline fn ringSubmission(q: *Queue) void {
    const off = 0x1000 + (@as(usize, q.id) * 2) * doorbell_stride;
    @as(*volatile u32, @ptrFromInt(mmio + off)).* = q.sq_tail;
}

inline fn ringCompletion(q: *Queue) void {
    const off = 0x1000 + (@as(usize, q.id) * 2 + 1) * doorbell_stride;
    @as(*volatile u32, @ptrFromInt(mmio + off)).* = q.cq_head;
}

/// Submit one command and wait for its completion.
fn submit(q: *Queue, cmd: SqEntry) ?CqEntry {
    var entry = cmd;
    entry.command_id = next_command_id;
    next_command_id +%= 1;
    if (next_command_id == 0) next_command_id = 1;

    q.sq[@as(usize, q.sq_tail)] = entry;
    q.sq_tail = (q.sq_tail + 1) % QUEUE_DEPTH;
    ringSubmission(q);

    const deadline = tsc.microsSinceBoot() + 5_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        const c = q.cq[@as(usize, q.cq_head)];
        // The low bit of status is the phase; everything above it is the
        // actual status code.
        if (c.status & 1 == q.phase) {
            const result = c;

            q.cq_head = (q.cq_head + 1) % QUEUE_DEPTH;
            if (q.cq_head == 0) q.phase ^= 1;
            ringCompletion(q);

            return result;
        }
        if (r32(REG_CSTS) & CSTS_CFS != 0) return null; // controller fault
        asm volatile ("pause");
    }
    return null;
}

fn succeeded(c: CqEntry) bool {
    // Status code is bits 1..15; zero means success.
    return (c.status >> 1) == 0;
}

fn allocQueue(id: u16) Error!Queue {
    const sq_phys = try pmm.allocPageZeroed();
    const cq_phys = try pmm.allocPageZeroed();
    return .{
        .sq = @ptrFromInt(pmm.physToVirt(sq_phys)),
        .sq_phys = sq_phys,
        .cq = @ptrFromInt(pmm.physToVirt(cq_phys)),
        .cq_phys = cq_phys,
        .id = id,
    };
}

fn disableController() Error!void {
    w32(REG_CC, r32(REG_CC) & ~CC_EN);

    const deadline = tsc.microsSinceBoot() + 5_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(REG_CSTS) & CSTS_RDY == 0) return;
        asm volatile ("pause");
    }
    return Error.Timeout;
}

fn enableController() Error!void {
    // IOSQES 6 and IOCQES 4 are log2 of the 64-byte command and 16-byte
    // completion sizes. MPS 0 means 4 KiB pages. CSS 0 is the NVM command set.
    const cc: u32 = CC_EN | (0 << 4) | (0 << 7) | (0 << 11) | (6 << 16) | (4 << 20);
    w32(REG_CC, cc);

    const deadline = tsc.microsSinceBoot() + 5_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        const csts = r32(REG_CSTS);
        if (csts & CSTS_CFS != 0) return Error.ControllerFault;
        if (csts & CSTS_RDY != 0) return;
        asm volatile ("pause");
    }
    return Error.Timeout;
}

/// Identify, then read the namespace to find its size and block size.
fn identifyNamespace() bool {
    const buf_phys = pmm.allocPageZeroed() catch return false;
    const buf_virt = pmm.physToVirt(buf_phys);

    // CNS 0: identify a namespace.
    const c = submit(&admin, .{
        .opcode = ADMIN_IDENTIFY,
        .flags = 0,
        .command_id = 0,
        .nsid = namespace_id,
        .reserved = 0,
        .metadata = 0,
        .prp1 = buf_phys,
        .prp2 = 0,
        .cdw10 = 0,
        .cdw11 = 0,
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    }) orelse return false;
    if (!succeeded(c)) return false;

    const data: [*]const u8 = @ptrFromInt(buf_virt);

    // NSZE at offset 0: total blocks.
    namespace_blocks = std.mem.readInt(u64, data[0..8], .little);
    if (namespace_blocks == 0) return false;

    // FLBAS at 26 selects which LBA format is in use; the format table starts
    // at 128, each entry 4 bytes, with LBADS as a log2 in byte 2.
    const flbas = data[26] & 0x0F;
    const fmt_off = 128 + @as(usize, flbas) * 4;
    const lbads = data[fmt_off + 2];
    if (lbads >= 9 and lbads <= 16) {
        namespace_block_size = @as(usize, 1) << @intCast(lbads);
    }

    return true;
}

fn createIoQueues() bool {
    io = allocQueue(IO_QUEUE_ID) catch return false;

    // Completion queue first: the submission queue references it.
    // PC bit means the queue is physically contiguous.
    const cq = submit(&admin, .{
        .opcode = ADMIN_CREATE_CQ,
        .flags = 0,
        .command_id = 0,
        .nsid = 0,
        .reserved = 0,
        .metadata = 0,
        .prp1 = io.cq_phys,
        .prp2 = 0,
        .cdw10 = (@as(u32, QUEUE_DEPTH - 1) << 16) | @as(u32, IO_QUEUE_ID),
        .cdw11 = 1, // PC
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    }) orelse return false;
    if (!succeeded(cq)) return false;

    const sq = submit(&admin, .{
        .opcode = ADMIN_CREATE_SQ,
        .flags = 0,
        .command_id = 0,
        .nsid = 0,
        .reserved = 0,
        .metadata = 0,
        .prp1 = io.sq_phys,
        .prp2 = 0,
        .cdw10 = (@as(u32, QUEUE_DEPTH - 1) << 16) | @as(u32, IO_QUEUE_ID),
        .cdw11 = (@as(u32, IO_QUEUE_ID) << 16) | 1, // paired CQ, PC
        .cdw12 = 0,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    }) orelse return false;

    return succeeded(sq);
}

/// One read or write, of at most BOUNCE_PAGES worth of blocks.
fn transfer(opcode: u8, lba: u64, count: u16) bool {
    const c = submit(&io, .{
        .opcode = opcode,
        .flags = 0,
        .command_id = 0,
        .nsid = namespace_id,
        .reserved = 0,
        .metadata = 0,
        .prp1 = bounce_phys,
        // PRP2 covers the second page. Anything beyond two pages would need a
        // PRP list, which is why transfers are chunked to this size.
        .prp2 = bounce_phys + pmm.PAGE_SIZE,
        .cdw10 = @truncate(lba),
        .cdw11 = @truncate(lba >> 32),
        // Block count is zero-based: 0 means one block.
        .cdw12 = count - 1,
        .cdw13 = 0,
        .cdw14 = 0,
        .cdw15 = 0,
    }) orelse return false;

    return succeeded(c);
}

fn blocksPerTransfer() u16 {
    return @intCast((BOUNCE_PAGES * pmm.PAGE_SIZE) / namespace_block_size);
}

fn readSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]u8) block.Error!void {
    _ = ctx;
    const per = blocksPerTransfer();

    var done: u32 = 0;
    while (done < count) {
        const chunk: u16 = @intCast(@min(count - done, per));
        if (!transfer(NVM_READ, lba + done, chunk)) return block.Error.IoError;

        const src: [*]const u8 = @ptrFromInt(bounce_virt);
        const bytes = @as(usize, chunk) * namespace_block_size;
        @memcpy(buf[done * namespace_block_size ..][0..bytes], src[0..bytes]);
        done += chunk;
    }
}

fn writeSectors(ctx: *anyopaque, lba: u64, count: u32, buf: [*]const u8) block.Error!void {
    _ = ctx;
    const per = blocksPerTransfer();

    var done: u32 = 0;
    while (done < count) {
        const chunk: u16 = @intCast(@min(count - done, per));
        const dst: [*]u8 = @ptrFromInt(bounce_virt);
        const bytes = @as(usize, chunk) * namespace_block_size;
        @memcpy(dst[0..bytes], buf[done * namespace_block_size ..][0..bytes]);

        if (!transfer(NVM_WRITE, lba + done, chunk)) return block.Error.IoError;
        done += chunk;
    }
}

var dummy_ctx: u8 = 0;

pub fn init() Error!usize {
    // Class 1 mass storage, subclass 8 NVM, prog-if 2 NVMe.
    const dev = pci.findByClass(0x01, 0x08, 0x02) orelse return 0;
    dev.enableBusMaster();

    const bar = dev.bar(0) orelse return Error.NoDevice;
    mmio = try vmm.mapMmio(bar, 0x4000);

    const cap = r64(REG_CAP);
    // DSTRD is bits 35..32: doorbell stride is 4 << DSTRD bytes.
    const dstrd: u6 = @truncate((cap >> 32) & 0x0F);
    doorbell_stride = @as(usize, 4) << dstrd;

    try disableController();

    admin = try allocQueue(0);

    // Admin queue sizes are zero-based, like everything else here.
    w32(REG_AQA, (@as(u32, QUEUE_DEPTH - 1) << 16) | (QUEUE_DEPTH - 1));
    w64(REG_ASQ, admin.sq_phys);
    w64(REG_ACQ, admin.cq_phys);

    try enableController();

    bounce_phys = try pmm.allocOrderZeroed(pmm.orderFor(BOUNCE_PAGES));
    bounce_virt = pmm.physToVirt(bounce_phys);

    if (!identifyNamespace()) return Error.NoNamespace;
    if (!createIoQueues()) return Error.NoNamespace;

    const n = block.makeName("nvme0");
    _ = block.register(.{
        .name = n.buf,
        .name_len = n.len,
        .ctx = &dummy_ctx,
        .ops = .{ .read = readSectors, .write = writeSectors },
        .sectors = namespace_blocks,
        .sector_size = namespace_block_size,
    });

    present = true;

    const version = r32(REG_VS);
    console.print("[ ok ] nvme: {d}.{d}, namespace {d}, {d} blocks of {d} bytes\n", .{
        (version >> 16) & 0xFFFF, (version >> 8) & 0xFF,
        namespace_id, namespace_blocks, namespace_block_size,
    });

    return 1;
}

pub fn isPresent() bool {
    return present;
}
