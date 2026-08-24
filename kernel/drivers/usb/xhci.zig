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
const TRB_NORMAL: u32 = 1;
const TRB_SETUP_STAGE: u32 = 2;
const TRB_DATA_STAGE: u32 = 3;
const TRB_STATUS_STAGE: u32 = 4;
const TRB_LINK: u32 = 6;
const TRB_ENABLE_SLOT: u32 = 9;
const TRB_ADDRESS_DEVICE: u32 = 11;
const TRB_CONFIGURE_ENDPOINT: u32 = 12;
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
var devices_addressed: usize = 0;

// ── Device state ────────────────────────────────────────────────────────────

pub const MAX_DEVICES = 8;

/// USB standard descriptor, as it arrives on the wire.
pub const DeviceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    usb_version: u16 align(1),
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    max_packet_size0: u8,
    vendor_id: u16 align(1),
    product_id: u16 align(1),
    device_version: u16 align(1),
    manufacturer_index: u8,
    product_index: u8,
    serial_index: u8,
    num_configurations: u8,
};

const Device = struct {
    used: bool = false,
    slot: u8 = 0,
    port: u8 = 0,
    speed: u8 = 0,

    /// Physical addresses of the structures the controller reads.
    input_ctx_phys: u64 = 0,
    device_ctx_phys: u64 = 0,
    ep0_ring_phys: u64 = 0,
    ep0_ring: [*]volatile Trb = undefined,
    ep0_enqueue: usize = 0,
    ep0_cycle: u32 = 1,

    /// A page the controller DMAs descriptor data into.
    buffer_phys: u64 = 0,
    buffer_virt: u64 = 0,

    descriptor: DeviceDescriptor = undefined,
    has_descriptor: bool = false,

    /// Taken from the first interface descriptor. A composite device reports
    /// class 0 at device level and the real class per interface.
    interface_class: u8 = 0,
    interface_subclass: u8 = 0,
    interface_protocol: u8 = 0,
    /// Address and packet size of the first IN interrupt endpoint, which is
    /// how a HID device delivers reports.
    interrupt_ep: u8 = 0,
    interrupt_max_packet: u16 = 0,
};

var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;
var device_count: usize = 0;

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

// ── Contexts and control transfers ──────────────────────────────────────────
//
// A device is described to the controller by a Device Context: a slot context
// followed by one endpoint context per endpoint. Software never writes it
// directly. Instead it fills in an Input Context - an add/drop bitmap followed
// by the same layout - and hands that to a command, which tells the controller
// which entries to consult.
//
// Context entries are `context_size` bytes apart, which is 32 or 64 depending
// on HCCPARAMS1. Indexing them with a fixed stride is the single easiest way
// to build something the hardware reads at the wrong offsets.

inline fn ctxAt(base: u64, index: usize) [*]volatile u32 {
    return @ptrFromInt(base + index * context_size);
}

/// Maximum packet size for endpoint 0, which is fixed by the device's speed.
fn ep0MaxPacket(speed: u8) u16 {
    return switch (speed) {
        1 => 8, // full speed: 8 until the real value is read
        2 => 8, // low speed
        3 => 64, // high speed
        else => 512, // super speed and above
    };
}

/// Build the Input Context for Address Device and issue the command.
fn addressDevice(dev: *Device) bool {
    const input_virt = pmm.physToVirt(dev.input_ctx_phys);
    const device_virt = pmm.physToVirt(dev.device_ctx_phys);

    // Zero both: the controller reads fields we do not set.
    const iv: [*]volatile u8 = @ptrFromInt(input_virt);
    var i: usize = 0;
    while (i < context_size * 3) : (i += 1) iv[i] = 0;
    const dv: [*]volatile u8 = @ptrFromInt(device_virt);
    i = 0;
    while (i < context_size * 2) : (i += 1) dv[i] = 0;

    // Input Control Context: add the slot context and endpoint 0.
    const icc = ctxAt(input_virt, 0);
    icc[1] = 0b11; // A0 (slot) and A1 (EP0)

    // Slot context: one context entry, the device's speed, and which root hub
    // port it is behind.
    const slot_ctx = ctxAt(input_virt, 1);
    slot_ctx[0] = (@as(u32, 1) << 27) | (@as(u32, dev.speed) << 20);
    slot_ctx[1] = @as(u32, dev.port) << 16;

    // Endpoint 0 context: control endpoint, three retries, max packet size,
    // and where its transfer ring starts.
    const ep0 = ctxAt(input_virt, 2);
    ep0[1] = (3 << 1) | (4 << 3) | (@as(u32, ep0MaxPacket(dev.speed)) << 16);
    ep0[2] = @truncate(dev.ep0_ring_phys | 1); // dequeue cycle state
    ep0[3] = @truncate(dev.ep0_ring_phys >> 32);
    ep0[4] = 8; // average TRB length

    dcbaa[dev.slot] = dev.device_ctx_phys;

    submitCommand(dev.input_ctx_phys, 0, TRB_ADDRESS_DEVICE | (@as(u32, dev.slot) << 14));
    const e = waitCommand(1_000_000) orelse return false;
    return e.completion_code == 1;
}

/// Put one TRB on an endpoint's transfer ring.
fn enqueueTransfer(dev: *Device, param: u64, status: u32, control: u32) void {
    dev.ep0_ring[dev.ep0_enqueue] = .{
        .param_lo = @truncate(param),
        .param_hi = @truncate(param >> 32),
        .status = status,
        .control = control | dev.ep0_cycle,
    };

    dev.ep0_enqueue += 1;
    if (dev.ep0_enqueue == RING_SIZE - 1) {
        dev.ep0_ring[RING_SIZE - 1].control =
            (TRB_LINK << 10) | (1 << 1) | dev.ep0_cycle;
        dev.ep0_enqueue = 0;
        dev.ep0_cycle ^= 1;
    }
}

/// A control transfer is three TRBs: a setup stage carrying the eight-byte
/// request, an optional data stage, and a status stage in the opposite
/// direction that acknowledges it.
fn controlIn(dev: *Device, request_type: u8, request: u8, value: u16, index: u16, length: u16) bool {
    const setup: u64 = @as(u64, request_type) |
        (@as(u64, request) << 8) |
        (@as(u64, value) << 16) |
        (@as(u64, index) << 32) |
        (@as(u64, length) << 48);

    // Transfer type 3 = IN data stage. IDT means the parameter field *is* the
    // data rather than a pointer to it.
    const setup_ctrl = (TRB_SETUP_STAGE << 10) | (1 << 6) | (@as(u32, 3) << 16);
    enqueueTransfer(dev, setup, 8, setup_ctrl);

    if (length > 0) {
        const data_ctrl = (TRB_DATA_STAGE << 10) | (1 << 16); // DIR = IN
        enqueueTransfer(dev, dev.buffer_phys, length, data_ctrl);
    }

    // Status stage runs opposite to the data stage, and asks for an event.
    const status_ctrl = (TRB_STATUS_STAGE << 10) | (1 << 5); // IOC
    enqueueTransfer(dev, 0, 0, status_ctrl);

    // Doorbell target 1 is endpoint 0.
    ringDoorbell(dev.slot, 1);

    const deadline = tsc.microsSinceBoot() + 1_000_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (pollEvent()) |e| {
            if (e.trb_type != TRB_TRANSFER_EVENT) continue;
            // 1 = success, 13 = short packet, which is fine for a descriptor
            // read that returned less than the maximum requested.
            return e.completion_code == 1 or e.completion_code == 13;
        }
        asm volatile ("pause");
    }
    return false;
}

fn readDeviceDescriptor(dev: *Device) bool {
    // 0x80: device to host, standard, device. Request 6 = GET_DESCRIPTOR,
    // value 0x0100 = device descriptor, index 0.
    if (!controlIn(dev, 0x80, 6, 0x0100, 0, 18)) return false;

    const src: *align(1) const DeviceDescriptor = @ptrFromInt(dev.buffer_virt);
    dev.descriptor = src.*;
    dev.has_descriptor = dev.descriptor.length >= 18 and dev.descriptor.descriptor_type == 1;
    return dev.has_descriptor;
}

/// Read the configuration descriptor and walk the descriptors that follow it.
///
/// They arrive as a single blob of variable-length records, each starting with
/// its own length, so walking means stepping by whatever each one declares.
/// A zero length would loop forever, which is why it is checked.
fn readConfiguration(dev: *Device) bool {
    // First nine bytes give wTotalLength, so the full read can be sized.
    if (!controlIn(dev, 0x80, 6, 0x0200, 0, 9)) return false;

    const head: [*]const u8 = @ptrFromInt(dev.buffer_virt);
    const total: u16 = @as(u16, head[2]) | (@as(u16, head[3]) << 8);
    if (total < 9 or total > 512) return false;

    if (!controlIn(dev, 0x80, 6, 0x0200, 0, total)) return false;

    const buf: [*]const u8 = @ptrFromInt(dev.buffer_virt);
    var off: usize = 0;
    var found_interface = false;

    while (off + 2 <= total) {
        const len = buf[off];
        const dtype = buf[off + 1];
        if (len == 0) break;

        switch (dtype) {
            0x04 => { // interface
                if (!found_interface and off + 9 <= total) {
                    dev.interface_class = buf[off + 5];
                    dev.interface_subclass = buf[off + 6];
                    dev.interface_protocol = buf[off + 7];
                    found_interface = true;
                }
            },
            0x05 => { // endpoint
                if (off + 7 <= total) {
                    const addr = buf[off + 2];
                    const attrs = buf[off + 3];
                    // Bit 7 of the address means IN; attribute bits 0-1 of 3
                    // means interrupt.
                    if (addr & 0x80 != 0 and attrs & 0x03 == 0x03 and dev.interrupt_ep == 0) {
                        dev.interrupt_ep = addr;
                        dev.interrupt_max_packet =
                            @as(u16, buf[off + 4]) | (@as(u16, buf[off + 5]) << 8);
                    }
                }
            },
            else => {},
        }

        off += len;
    }

    return found_interface;
}

fn allocDevice(slot: u8, port: u8, speed: u8) ?*Device {
    if (device_count >= MAX_DEVICES) return null;

    const d = &devices[device_count];
    d.* = .{ .used = true, .slot = slot, .port = port, .speed = speed };

    d.input_ctx_phys = pmm.allocPageZeroed() catch return null;
    d.device_ctx_phys = pmm.allocPageZeroed() catch return null;
    d.ep0_ring_phys = pmm.allocPageZeroed() catch return null;
    d.buffer_phys = pmm.allocPageZeroed() catch return null;

    d.ep0_ring = @ptrFromInt(pmm.physToVirt(d.ep0_ring_phys));
    d.buffer_virt = pmm.physToVirt(d.buffer_phys);
    linkRing(d.ep0_ring, d.ep0_ring_phys, true);

    device_count += 1;
    return d;
}

/// Describe a device from whichever class field actually carries meaning.
fn describe(dev: *const Device) []const u8 {
    const class = if (dev.descriptor.device_class != 0)
        dev.descriptor.device_class
    else
        dev.interface_class;

    return switch (class) {
        0x03 => switch (dev.interface_protocol) {
            1 => "HID keyboard",
            2 => "HID mouse",
            else => "HID device",
        },
        0x08 => "mass storage",
        0x09 => "hub",
        0x01 => "audio",
        0x02 => "communications",
        0xFF => "vendor specific",
        else => "device",
    };
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

            const dev = allocDevice(slot, port, @truncate(speed)) orelse {
                console.print("[warn] usb: port {d} out of device slots\n", .{port});
                continue;
            };

            if (!addressDevice(dev)) {
                console.print("[warn] usb: port {d} slot {d} would not address\n", .{ port, slot });
                continue;
            }
            devices_addressed += 1;

            if (readDeviceDescriptor(dev)) {
                _ = readConfiguration(dev);
                const d = &dev.descriptor;
                console.print("[ ok ] usb: port {d} slot {d}  {x:0>4}:{x:0>4}  USB {x}.{x}  {s}\n", .{
                    port,          slot,
                    d.vendor_id,   d.product_id,
                    (d.usb_version >> 8) & 0xFF, (d.usb_version >> 4) & 0x0F,
                    describe(dev),
                });
                if (dev.interrupt_ep != 0) {
                    console.print("[info]   interrupt endpoint 0x{x}, {d}-byte reports\n", .{
                        dev.interrupt_ep, dev.interrupt_max_packet,
                    });
                }
            } else {
                console.print("[warn] usb: port {d} slot {d} addressed but no descriptor\n", .{ port, slot });
            }
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

pub fn stats() struct { connected: usize, slots: usize, addressed: usize } {
    return .{
        .connected = ports_connected,
        .slots = slots_enabled,
        .addressed = devices_addressed,
    };
}

pub fn deviceList() []const Device {
    return devices[0..device_count];
}
