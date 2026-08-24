//! Intel High Definition Audio.
//!
//! HDA splits cleanly in two. The *controller* is a DMA engine with a pair of
//! ring buffers (CORB out, RIRB in) for talking to codecs, and a set of stream
//! descriptors that pull sample data out of memory. The *codec* is a graph of
//! widgets — converters, pins, mixers — that has to be walked to discover
//! which node turns samples into sound and which pin it comes out of.
//!
//! The graph walk is the awkward part, and it is not optional: node IDs differ
//! between codecs, so hardcoding QEMU's numbers would produce a driver that
//! works on exactly one machine.

const std = @import("std");
const pci = @import("../../dev/pci/pci.zig");
const vmm = @import("../../mm/vmm.zig");
const pmm = @import("../../mm/pmm.zig");
const console = @import("../../console.zig");
const tsc = @import("../../time/tsc.zig");

// Controller registers.
const REG_GCAP: usize = 0x00;
const REG_GCTL: usize = 0x08;
const REG_STATESTS: usize = 0x0E;
const REG_CORBLBASE: usize = 0x40;
const REG_CORBUBASE: usize = 0x44;
const REG_CORBWP: usize = 0x48;
const REG_CORBRP: usize = 0x4A;
const REG_CORBCTL: usize = 0x4C;
const REG_CORBSIZE: usize = 0x4E;
const REG_RIRBLBASE: usize = 0x50;
const REG_RIRBUBASE: usize = 0x54;
const REG_RIRBWP: usize = 0x58;
const REG_RINTCNT: usize = 0x5A;
const REG_RIRBCTL: usize = 0x5C;
const REG_RIRBSTS: usize = 0x5D;
const REG_RIRBSIZE: usize = 0x5E;

// Immediate command interface. A single command register, a single response
// register, and a busy/valid handshake - no rings, no DMA, no pointers to keep
// in step. CORB/RIRB exists for high command throughput; codec configuration
// issues a few dozen verbs at boot and needs none of it.
const REG_ICOI: usize = 0x60;
const REG_ICII: usize = 0x64;
const REG_ICIS: usize = 0x68;

const ICIS_BUSY: u16 = 1 << 0;
const ICIS_VALID: u16 = 1 << 1;

const GCTL_CRST: u32 = 1 << 0;
const CORBCTL_RUN: u8 = 1 << 1;
const RIRBCTL_RUN: u8 = 1 << 1;
const CORBRP_RST: u16 = 1 << 15;

// Stream descriptor, relative to its own base.
const SD_CTL: usize = 0x00;
const SD_STS: usize = 0x03;
const SD_LPIB: usize = 0x04;
const SD_CBL: usize = 0x08;
const SD_LVI: usize = 0x0C;
const SD_FMT: usize = 0x12;
const SD_BDPL: usize = 0x18;
const SD_BDPU: usize = 0x1C;

const SDCTL_RUN: u32 = 1 << 1;
const SDCTL_SRST: u32 = 1 << 0;

// Codec verbs.
const VERB_GET_PARAM: u32 = 0xF00;
const VERB_SET_FORMAT: u32 = 0x200;
const VERB_SET_STREAM_CHANNEL: u32 = 0x706;
const VERB_SET_AMP: u32 = 0x300;
const VERB_SET_PIN_CTL: u32 = 0x707;
const VERB_SET_POWER: u32 = 0x705;
const VERB_SET_EAPD: u32 = 0x70C;

// Parameters.
const PARAM_NODE_COUNT: u32 = 0x04;
const PARAM_FUNCTION_TYPE: u32 = 0x05;
const PARAM_WIDGET_CAP: u32 = 0x09;
const PARAM_PIN_CAP: u32 = 0x0C;

const WIDGET_OUTPUT: u4 = 0x0;
const WIDGET_PIN: u4 = 0x4;

const FUNCTION_AUDIO: u8 = 0x01;

pub const SAMPLE_RATE: u32 = 48000;
pub const CHANNELS: usize = 2;

pub const Error = error{
    NoDevice,
    NoCodec,
    NoOutput,
    Timeout,
    OutOfMemory,
    InvalidOrder,
} || vmm.Error;

var mmio: u64 = 0;
var present: bool = false;

var codec_addr: u8 = 0;
var dac_node: u8 = 0;
var pin_node: u8 = 0;
var output_stream_base: usize = 0;

/// Playback buffer. One second at 48 kHz stereo 16-bit is 192 KiB.
const BUFFER_BYTES: usize = 192 * 1024;
var buffer_phys: u64 = 0;
var buffer_virt: u64 = 0;
var bdl_phys: u64 = 0;

inline fn r8(o: usize) u8 {
    return @as(*volatile u8, @ptrFromInt(mmio + o)).*;
}
inline fn w8(o: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(mmio + o)).* = v;
}
inline fn r16(o: usize) u16 {
    return @as(*volatile u16, @ptrFromInt(mmio + o)).*;
}
inline fn w16(o: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(mmio + o)).* = v;
}
inline fn r32(o: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(mmio + o)).*;
}
inline fn w32(o: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(mmio + o)).* = v;
}

// ── Codec commands ──────────────────────────────────────────────────────────

/// Send one verb and wait for its response, over the immediate interface.
///
/// The handshake is: wait for the controller to be idle, write the command,
/// set the busy bit, wait for the result-valid bit, read the response, and
/// clear valid ready for the next one.
fn sendVerb(value: u32) ?u32 {
    var deadline = tsc.microsSinceBoot() + 100_000;
    while (r16(REG_ICIS) & ICIS_BUSY != 0) {
        if (tsc.microsSinceBoot() > deadline) return null;
        asm volatile ("pause");
    }

    // Clear any stale result before issuing a new command, or the first poll
    // below would accept the previous response.
    w16(REG_ICIS, ICIS_VALID);

    w32(REG_ICOI, value);
    w16(REG_ICIS, ICIS_BUSY);

    deadline = tsc.microsSinceBoot() + 100_000;
    while (tsc.microsSinceBoot() < deadline) {
        const status = r16(REG_ICIS);
        if (status & ICIS_VALID != 0) {
            const resp = r32(REG_ICII);
            w16(REG_ICIS, ICIS_VALID);
            return resp;
        }
        asm volatile ("pause");
    }
    return null;
}

/// Verb with an 8-bit payload (get parameter, set power, pin control).
fn command(codec: u8, node: u8, verb: u32, payload: u32) ?u32 {
    return sendVerb((@as(u32, codec) << 28) |
        (@as(u32, node) << 20) |
        ((verb & 0xFFF) << 8) |
        (payload & 0xFF));
}

/// Verb with a 16-bit payload (stream format, amplifier gain). The verb field
/// shrinks to four bits to make room for the data.
fn commandWide(codec: u8, node: u8, verb: u32, payload: u16) ?u32 {
    return sendVerb((@as(u32, codec) << 28) |
        (@as(u32, node) << 20) |
        ((verb & 0xF00) << 8) |
        payload);
}

// ── Discovery ───────────────────────────────────────────────────────────────

/// Walk the codec's widget graph looking for an output converter and a pin.
/// Node numbering is codec-specific, so this has to be discovered rather than
/// assumed.
fn findOutput(codec: u8) bool {
    const root = command(codec, 0, VERB_GET_PARAM, PARAM_NODE_COUNT) orelse return false;
    const fg_start: u8 = @truncate(root >> 16);
    const fg_count: u8 = @truncate(root);

    var fg: u8 = 0;
    while (fg < fg_count) : (fg += 1) {
        const fg_node = fg_start + fg;

        const ftype = command(codec, fg_node, VERB_GET_PARAM, PARAM_FUNCTION_TYPE) orelse continue;
        if (@as(u8, @truncate(ftype)) != FUNCTION_AUDIO) continue;

        // Power the function group up before asking it anything useful.
        _ = command(codec, fg_node, VERB_SET_POWER, 0);

        const sub = command(codec, fg_node, VERB_GET_PARAM, PARAM_NODE_COUNT) orelse continue;
        const start: u8 = @truncate(sub >> 16);
        const count: u8 = @truncate(sub);

        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const node = start + i;
            const caps = command(codec, node, VERB_GET_PARAM, PARAM_WIDGET_CAP) orelse continue;
            const kind: u4 = @truncate(caps >> 20);

            if (kind == WIDGET_OUTPUT and dac_node == 0) {
                dac_node = node;
                _ = command(codec, node, VERB_SET_POWER, 0);
            } else if (kind == WIDGET_PIN and pin_node == 0) {
                const pin_caps = command(codec, node, VERB_GET_PARAM, PARAM_PIN_CAP) orelse continue;
                // Bit 4: this pin can drive an output.
                if (pin_caps & (1 << 4) == 0) continue;
                pin_node = node;
                _ = command(codec, node, VERB_SET_POWER, 0);
            }

            if (dac_node != 0 and pin_node != 0) return true;
        }
    }
    return dac_node != 0;
}

// ── Setup ───────────────────────────────────────────────────────────────────

fn resetController() Error!void {
    // Leave reset, then wait for the controller to say it is out.
    w32(REG_GCTL, r32(REG_GCTL) & ~GCTL_CRST);
    tsc.busyWaitUs(1000);
    w32(REG_GCTL, r32(REG_GCTL) | GCTL_CRST);

    const deadline = tsc.microsSinceBoot() + 500_000;
    while (tsc.microsSinceBoot() < deadline) {
        if (r32(REG_GCTL) & GCTL_CRST != 0) break;
        asm volatile ("pause");
    } else return Error.Timeout;

    // Codecs need time to report their presence after a reset.
    tsc.busyWaitUs(1000);
}

/// The command rings are left stopped: everything here goes through the
/// immediate interface instead. They are explicitly disabled rather than left
/// in whatever state reset produced.
fn setupRings() Error!void {
    w8(REG_CORBCTL, 0);
    w8(REG_RIRBCTL, 0);

}

/// Buffer Descriptor List: one entry pointing at the whole playback buffer.
fn setupStream() Error!void {
    buffer_phys = try pmm.allocOrderZeroed(pmm.orderFor(BUFFER_BYTES / pmm.PAGE_SIZE));
    buffer_virt = pmm.physToVirt(buffer_phys);

    bdl_phys = try pmm.allocPageZeroed();
    const bdl: [*]volatile u64 = @ptrFromInt(pmm.physToVirt(bdl_phys));

    // Two entries covering the same buffer: the hardware wants at least two,
    // and pointing both at one buffer makes playback loop.
    bdl[0] = buffer_phys;
    bdl[1] = BUFFER_BYTES / 2; // length, with IOC clear
    bdl[2] = buffer_phys + BUFFER_BYTES / 2;
    bdl[3] = BUFFER_BYTES / 2;

    const sd = output_stream_base;

    // Reset the stream descriptor before configuring it.
    w32(sd + SD_CTL, SDCTL_SRST);
    tsc.busyWaitUs(1000);
    w32(sd + SD_CTL, 0);
    tsc.busyWaitUs(1000);

    @as(*volatile u32, @ptrFromInt(mmio + sd + SD_BDPL)).* = @truncate(bdl_phys);
    @as(*volatile u32, @ptrFromInt(mmio + sd + SD_BDPU)).* = @truncate(bdl_phys >> 32);
    @as(*volatile u32, @ptrFromInt(mmio + sd + SD_CBL)).* = BUFFER_BYTES;
    @as(*volatile u16, @ptrFromInt(mmio + sd + SD_LVI)).* = 1; // last valid index

    // Format: 48 kHz, 16-bit, 2 channels.
    const fmt: u16 = (0 << 14) | (0 << 11) | (1 << 4) | (CHANNELS - 1);
    @as(*volatile u16, @ptrFromInt(mmio + sd + SD_FMT)).* = fmt;

    // Stream number 1, channel 0.
    w32(sd + SD_CTL, (1 << 20));

    _ = commandWide(codec_addr, dac_node, VERB_SET_FORMAT, fmt);
    _ = command(codec_addr, dac_node, VERB_SET_STREAM_CHANNEL, 0x10); // stream 1
    // Unmute the converter and the pin, output amps, both channels.
    _ = commandWide(codec_addr, dac_node, VERB_SET_AMP, 0xB000 | 0x7F);
    if (pin_node != 0) {
        _ = commandWide(codec_addr, pin_node, VERB_SET_AMP, 0xB000 | 0x7F);
        _ = command(codec_addr, pin_node, VERB_SET_PIN_CTL, 0x40); // output enable
        _ = command(codec_addr, pin_node, VERB_SET_EAPD, 0x02);
    }
}

pub fn init() Error!bool {
    // Class 4 (multimedia), subclass 3 (HD Audio).
    const dev = pci.findByClass(0x04, 0x03, null) orelse return false;
    dev.enableBusMaster();

    const bar = dev.bar(0) orelse return Error.NoDevice;
    mmio = try vmm.mapMmio(bar, 0x4000);

    try resetController();

    const statests = r16(REG_STATESTS);
    if (statests == 0) return Error.NoCodec;

    try setupRings();
    tsc.busyWaitUs(1000);

    // Lowest set bit is the first codec that answered.
    var c: u8 = 0;
    while (c < 15) : (c += 1) {
        if (statests & (@as(u16, 1) << @intCast(c)) != 0) break;
    }
    codec_addr = c;

    if (!findOutput(codec_addr)) return Error.NoOutput;

    // Output streams follow input streams; GCAP says how many of each.
    const gcap = r16(REG_GCAP);
    const in_streams: usize = (gcap >> 8) & 0x0F;
    output_stream_base = 0x80 + in_streams * 0x20;

    try setupStream();

    present = true;
    return true;
}

// ── Playback ────────────────────────────────────────────────────────────────

/// A quarter sine, scaled to 16-bit. There is no floating point in the kernel,
/// so the table is generated at comptime and the other three quadrants are
/// mirrored from it.
const SINE_STEPS = 256;
const sine_table = blk: {
    @setEvalBranchQuota(100_000);
    var t: [SINE_STEPS]i16 = undefined;
    for (&t, 0..) |*v, i| {
        const x: f64 = @as(f64, @floatFromInt(i)) * std.math.pi * 2.0 / SINE_STEPS;
        v.* = @intFromFloat(@sin(x) * 12000.0);
    }
    break :blk t;
};

/// Fill the buffer with a tone and start the stream.
pub fn playTone(freq: u32, amplitude_shift: u4) void {
    if (!present) return;

    const samples: [*]volatile i16 = @ptrFromInt(buffer_virt);
    const frames = BUFFER_BYTES / (2 * CHANNELS);

    var phase: u64 = 0;
    const step: u64 = (@as(u64, freq) * SINE_STEPS * 65536) / SAMPLE_RATE;

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const idx: usize = @intCast((phase >> 16) % SINE_STEPS);
        const v: i16 = sine_table[idx] >> amplitude_shift;
        samples[i * CHANNELS] = v;
        samples[i * CHANNELS + 1] = v;
        phase += step;
    }

    const sd = output_stream_base;
    w32(sd + SD_CTL, r32(sd + SD_CTL) | SDCTL_RUN);
}

pub fn stop() void {
    if (!present) return;
    const sd = output_stream_base;
    w32(sd + SD_CTL, r32(sd + SD_CTL) & ~SDCTL_RUN);
}

/// Link position in the buffer. Advancing means DMA is genuinely running.
pub fn position() u32 {
    if (!present) return 0;
    return r32(output_stream_base + SD_LPIB);
}

pub fn isPresent() bool {
    return present;
}

pub fn report() void {
    if (!present) {
        console.info("no HD Audio device", .{});
        return;
    }
    console.print("[ ok ] hda: codec {d}, dac node {d}, pin node {d}\n", .{
        codec_addr, dac_node, pin_node,
    });
}
