//! xHCI — USB 3.x host controller.
//!
//! Everything the controller does is driven by rings of 16-byte Transfer
//! Request Blocks. Software produces on the command ring, hardware produces on
//! the event ring, and both sides agree on where the producer has got to using
//! a *cycle bit* that flips each time the producer wraps. A consumer stops
//! when it sees a TRB whose cycle bit does not match the cycle it expects.
//! That single mechanism replaces head and tail pointers entirely, and getting
//! it wrong means the controller silently ignores every command.
//!
//! The other trap is context size. HCCPARAMS1 bit 2 says whether device and
//! input contexts are 32 or 64 bytes; assuming the smaller one on a controller
//! that wants the larger produces structures the hardware reads at the wrong
//! offsets, with no error to say so.

const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const console = @import("../../console.zig");
const tsc = @import("../../time/tsc.zig");

// Capability registers.
/// CAPLENGTH is a byte at 0x00 and HCIVERSION a 16-bit value at 0x02, so both
/// live in the dword at 0x00. Reading a u32 straight from 0x02 is misaligned
/// and faults.
const CAP_CAPLENGTH: usize = 0x00;
const CAP_HCSPARAMS1: usize = 0x04;
const CAP_HCCPARAMS1: usize = 0x10;
const CAP_DBOFF: usize = 0x14;
const CAP_RTSOFF: usize = 0x18;

// Operational registers, relative to the operational base.
const OP_USBCMD: usize = 0x00;
const OP_USBSTS: usize = 0x04;
const OP_PAGESIZE: usize = 0x08;
const OP_DNCTRL: usize = 0x14;
const OP_CRCR: usize = 0x18;
const OP_DCBAAP: usize = 0x30;
const OP_CONFIG: usize = 0x38;
const OP_PORTSC_BASE: usize = 0x400;

const USBCMD_RS: u32 = 1 << 0;
const USBCMD_HCRST: u32 = 1 << 1;
const USBCMD_INTE: u32 = 1 << 2;

const USBSTS_HCH: u32 = 1 << 0;
const USBSTS_CNR: u32 = 1 << 11;

const PORTSC_CCS: u32 = 1 << 0; // current connect status
const PORTSC_PED: u32 = 1 << 1; // port enabled
const PORTSC_PR: u32 = 1 << 4; // port reset
const PORTSC_PP: u32 = 1 << 9; // port power
const PORTSC_CSC: u32 = 1 << 17; // connect status change
const PORTSC_PRC: u32 = 1 << 21; // port reset change

/// Bits that are write-1-to-clear. Writing PORTSC without masking these off
/// clears status the driver has not looked at yet.
const PORTSC_RW1C: u32 = 0x00FE_0000;

// Runtime registers: interrupter 0 sits at RTSOFF + 0x20.
const RT_IR0: usize = 0x20;
const IR_IMAN: usize = 0x00;
const IR_IMOD: usize = 0x04;
const IR_ERSTSZ: usize = 0x08;
const IR_ERSTBA: usize = 0x10;
const IR_ERDP: usize = 0x18;

// TRB types.
const TRB_LINK: u32 = 6;
const TRB_ENABLE_SLOT: u32 = 9;
const TRB_NOOP_CMD: u32 = 23;
const TRB_TRANSFER_EVENT: u32 = 32;
const TRB_COMMAND_COMPLETE: u32 = 33;
const TRB_PORT_STATUS_CHANGE: u32 = 34;

const RING_SIZE: usize = 64;

pub const Error = error{
    NoDevice,
    Timeout,
    OutOfMemory,
    InvalidOrder,
    CommandFailed,
} || vmm.Error;

/// A Transfer Request Block: four 32-bit words, however it is being used.
const Trb = extern struct {
    param_lo: u32,
    param_hi: u32,
    status: u32,
    control: u32,
};

var mmio: u64 = 0;
var op_base: u64 = 0;
var rt_base: u64 = 0;
var db_base: u64 = 0;

var max_slots: u8 = 0;
var max_ports: u8 = 0;
var context_size: usize = 32;
var present: bool = false;

var dcbaa: [*]volatile u64 = undefined;

var cmd_ring: [*]volatile Trb = undefined;
var cmd_ring_phys: u64 = 0;
var cmd_enqueue: usize = 0;
var cmd_cycle: u32 = 1;

var event_ring: [*]volatile Trb = undefined;
var event_ring_phys: u64 = 0;
var event_dequeue: usize = 0;
var event_cycle: u32 = 1;

var ports_connected: usize = 0;
var slots_enabled: usize = 0;

inline fn r32(base: u64, off: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(base + off)).*;
}
inline fn w32(base: u64, off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(base + off)).* = v;
}
inline fn r64(base: u64, off: usize) u64 {
    return @as(*volatile u64, @ptrFromInt(base + off)).*;
}
inline fn w64(base: u64, off: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(base + off)).* = v;
}

inline fn portsc(port: u8) usize {
    return OP_PORTSC_BASE + (@as(usize, port) - 1) * 0x10;
}

// ── Bring-up ────────────────────────────────────────────────────────────────

fn waitReady() Error!void {
    const deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(op_base, OP_USBSTS) & USBSTS_CNR == 0) return;
        asm volatile ("pause");
    }
    return Error.Timeout;
}

fn reset() Error!void {
    // Stop first: resetting a running controller is undefined.
    w32(op_base, OP_USBCMD, r32(op_base, OP_USBCMD) & ~USBCMD_RS);

    var deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(op_base, OP_USBSTS) & USBSTS_HCH != 0) break;
        asm volatile ("pause");
    } else return Error.Timeout;

    w32(op_base, OP_USBCMD, USBCMD_HCRST);

    deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(op_base, OP_USBCMD) & USBCMD_HCRST == 0) break;
        asm volatile ("pause");
    } else return Error.Timeout;

    try waitReady();
}

/// Put a Link TRB at the end of a ring so the controller wraps to the start.
fn linkRing(ring: [*]volatile Trb, phys: u64, toggle: bool) void {
    ring[RING_SIZE - 1] = .{
        .param_lo = @truncate(phys),
        .param_hi = @truncate(phys >> 32),
        .status = 0,
        // Toggle Cycle tells the producer to flip its cycle bit on wrap, which
        // is what lets the consumer tell a fresh TRB from a stale one.
        .control = (TRB_LINK << 10) | (if (toggle) @as(u32, 1 << 1) else 0),
    };
}

fn setupRings() Error!void {
    // Device Context Base Address Array: one entry per slot, plus slot 0 which
    // points at the scratchpad array.
    const dcbaa_phys = try pmm.allocPageZeroed();
    dcbaa = @ptrFromInt(pmm.physToVirt(dcbaa_phys));
    w64(op_base, OP_DCBAAP, dcbaa_phys);

    // Command ring.
    cmd_ring_phys = try pmm.allocPageZeroed();
    cmd_ring = @ptrFromInt(pmm.physToVirt(cmd_ring_phys));
    linkRing(cmd_ring, cmd_ring_phys, true);
    cmd_enqueue = 0;
    cmd_cycle = 1;
    // Low bit of CRCR is the Ring Cycle State the controller starts with.
    w64(op_base, OP_CRCR, cmd_ring_phys | 1);

    // Event ring, described to the controller through a segment table.
    event_ring_phys = try pmm.allocPageZeroed();
    event_ring = @ptrFromInt(pmm.physToVirt(event_ring_phys));
    event_dequeue = 0;
    event_cycle = 1;

    const erst_phys = try pmm.allocPageZeroed();
    const erst: [*]volatile u64 = @ptrFromInt(pmm.physToVirt(erst_phys));
    erst[0] = event_ring_phys;
    erst[1] = RING_SIZE; // segment size in TRBs

    const ir = rt_base + RT_IR0;
    w32(ir, IR_ERSTSZ, 1);
    w64(ir, IR_ERDP, event_ring_phys);
    w64(ir, IR_ERSTBA, erst_phys);
}

pub fn init() Error!bool {
    // Class 0x0C serial bus, subclass 3 USB, prog-if 0x30 xHCI.
    const dev = pci.findByClass(0x0C, 0x03, 0x30) orelse return false;
    dev.enableBusMaster();

    const bar = dev.bar(0) orelse return Error.NoDevice;
    mmio = try vmm.mapMmio(bar, 0x10000);

    const caplen: u8 = @truncate(r32(mmio, CAP_CAPLENGTH));
    op_base = mmio + caplen;
    rt_base = mmio + (r32(mmio, CAP_RTSOFF) & ~@as(u32, 0x1F));
    db_base = mmio + (r32(mmio, CAP_DBOFF) & ~@as(u32, 0x3));

    const hcs1 = r32(mmio, CAP_HCSPARAMS1);
    max_slots = @truncate(hcs1);
    max_ports = @truncate(hcs1 >> 24);

    const hcc1 = r32(mmio, CAP_HCCPARAMS1);
    context_size = if (hcc1 & (1 << 2) != 0) 64 else 32;

    try reset();
    try setupRings();

    // Tell the controller how many slots we intend to use.
    w32(op_base, OP_CONFIG, max_slots);

    // Run. Interrupts stay masked: the event ring is polled, because nothing
    // can usefully block on a USB completion yet.
    w32(op_base, OP_USBCMD, r32(op_base, OP_USBCMD) | USBCMD_RS);

    const deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(op_base, OP_USBSTS) & USBSTS_HCH == 0) break;
        asm volatile ("pause");
    } else return Error.Timeout;

    present = true;
    return true;
}

// ── Command ring ────────────────────────────────────────────────────────────

fn ringDoorbell(slot: u8, target: u32) void {
    @as(*volatile u32, @ptrFromInt(db_base + @as(usize, slot) * 4)).* = target;
}

/// Put a TRB on the command ring and ring the doorbell.
fn submitCommand(param: u64, status: u32, trb_type: u32) void {
    cmd_ring[cmd_enqueue] = .{
        .param_lo = @truncate(param),
        .param_hi = @truncate(param >> 32),
        .status = status,
        .control = (trb_type << 10) | cmd_cycle,
    };

    cmd_enqueue += 1;
    if (cmd_enqueue == RING_SIZE - 1) {
        // Hand the Link TRB to the controller with the current cycle, then
        // wrap and flip. Skipping the flip makes every later command look
        // stale and be ignored.
        cmd_ring[RING_SIZE - 1].control =
            (TRB_LINK << 10) | (1 << 1) | cmd_cycle;
        cmd_enqueue = 0;
        cmd_cycle ^= 1;
    }

    ringDoorbell(0, 0);
}

pub const Event = struct {
    trb_type: u32,
    completion_code: u8,
    slot_id: u8,
    param: u64,
};

/// Take the next event, or null if the controller has not produced one.
fn pollEvent() ?Event {
    const trb = event_ring[event_dequeue];
    if (trb.control & 1 != event_cycle) return null;

    const e = Event{
        .trb_type = (trb.control >> 10) & 0x3F,
        .completion_code = @truncate(trb.status >> 24),
        .slot_id = @truncate(trb.control >> 24),
        .param = (@as(u64, trb.param_hi) << 32) | trb.param_lo,
    };

    event_dequeue += 1;
    if (event_dequeue == RING_SIZE) {
        event_dequeue = 0;
        event_cycle ^= 1;
    }

    // Tell the controller how far we have consumed. Bit 3 clears the event
    // handler busy flag.
    const ir = rt_base + RT_IR0;
    w64(ir, IR_ERDP, (event_ring_phys + event_dequeue * @sizeOf(Trb)) | (1 << 3));

    return e;
}

/// Wait for a command completion event, draining anything else that arrives.
fn waitCommand(timeout_us: u64) ?Event {
    const deadline = tsc.microsSinceBoot() + timeout_us;
    while (tsc.microsSinceBoot() < deadline) {
        if (pollEvent()) |e| {
            if (e.trb_type == TRB_COMMAND_COMPLETE) return e;
            // Port status changes arrive unsolicited; keep looking.
            continue;
        }
        asm volatile ("pause");
    }
    return null;
}

// ── Ports ───────────────────────────────────────────────────────────────────

/// Reset a port and wait for it to enable. USB 2 devices need an explicit
/// reset; USB 3 devices enable themselves on connect.
fn resetPort(port: u8) bool {
    const off = portsc(port);
    const sc = r32(op_base, off);

    if (sc & PORTSC_PED != 0) return true; // already enabled

    // Preserve everything except the write-1-to-clear status bits, or reading
    // the port later loses changes we never saw.
    w32(op_base, off, (sc & ~PORTSC_RW1C) | PORTSC_PR);

    const deadline = tsc.microsSinceBoot() + 500_000;
    while (tsc.microsSinceBoot() < deadline) {
        const now = r32(op_base, off);
        if (now & PORTSC_PRC != 0) {
            w32(op_base, off, (now & ~PORTSC_RW1C) | PORTSC_PRC);
            return r32(op_base, off) & PORTSC_PED != 0;
        }
        asm volatile ("pause");
    }
    return false;
}

/// Ask the controller for a device slot.
fn enableSlot() ?u8 {
    submitCommand(0, 0, TRB_ENABLE_SLOT);
    const e = waitCommand(1_000_000) orelse return null;
    if (e.completion_code != 1) return null; // 1 = success
    return e.slot_id;
}

/// Walk the root hub, reset anything connected, and claim a slot for it.
pub fn enumerate() void {
    if (!present) return;

    var port: u8 = 1;
    while (port <= max_ports) : (port += 1) {
        const sc = r32(op_base, portsc(port));
        if (sc & PORTSC_CCS == 0) continue;

        ports_connected += 1;

        const enabled = resetPort(port);
        const speed = (sc >> 10) & 0x0F;

        if (!enabled) {
            console.print("[warn] usb: port {d} connected but would not enable\n", .{port});
            continue;
        }

        if (enableSlot()) |slot| {
            slots_enabled += 1;
            console.print("[ ok ] usb: port {d} device at slot {d}, speed {d}\n", .{
                port, slot, speed,
            });
        } else {
            console.print("[warn] usb: port {d} enabled but slot request failed\n", .{port});
        }
    }
}

/// Issue a No-Op command. It exercises the command ring, the doorbell and the
/// event ring without needing a device, which makes it the right first thing
/// to check when nothing else works.
pub fn commandRingWorks() bool {
    if (!present) return false;
    submitCommand(0, 0, TRB_NOOP_CMD);
    const e = waitCommand(1_000_000) orelse return false;
    return e.completion_code == 1;
}

pub fn isPresent() bool {
    return present;
}

pub fn report() void {
    if (!present) {
        console.info("no xHCI controller", .{});
        return;
    }
    const version = (r32(mmio, CAP_CAPLENGTH) >> 16) & 0xFFFF;
    console.print("[ ok ] xhci: version {x}.{x}, {d} ports, {d} slots, {d}-byte contexts\n", .{
        (version >> 8) & 0xFF, (version >> 4) & 0x0F, max_ports, max_slots, context_size,
    });
}

pub fn stats() struct { connected: usize, slots: usize } {
    return .{ .connected = ports_connected, .slots = slots_enabled };
}
