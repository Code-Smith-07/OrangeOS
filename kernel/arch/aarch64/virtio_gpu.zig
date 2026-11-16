//! virtio-gpu: the virtual machine's graphics card.
//!
//! This is the "paravirtual" way to draw, the idea Parallels and VMware
//! use: the guest does not pretend to drive a real video card. It keeps the
//! picture in ordinary memory and sends the host short messages ("this
//! rectangle changed, show it"). Drawing costs no traps at all; one message
//! a frame goes to the host.
//!
//! Stage A0 uses the 2D commands over the memory-mapped transport, and
//! waits for each answer by polling. Interrupts and the 3D path come with
//! the desktop (docs/design/015).

const cpu = @import("cpu.zig");

// ── virtio over memory-mapped registers (version 2) ────────────────────────
const MAGIC = 0x000;
const VERSION = 0x004;
const DEVICE_ID = 0x008;
const DEVICE_FEATURES_SEL = 0x014;
const DEVICE_FEATURES = 0x010;
const DRIVER_FEATURES = 0x020;
const DRIVER_FEATURES_SEL = 0x024;
const QUEUE_SEL = 0x030;
const QUEUE_NUM_MAX = 0x034;
const QUEUE_NUM = 0x038;
const QUEUE_READY = 0x044;
const QUEUE_NOTIFY = 0x050;
const STATUS = 0x070;
const QUEUE_DESC = 0x080;
const QUEUE_DRIVER = 0x090;
const QUEUE_DEVICE = 0x0A0;

const MAGIC_VALUE: u32 = 0x7472_6976; // "virt"
const ID_GPU: u32 = 16;
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const QUEUE_SIZE = 8;
const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const Descriptor = extern struct { address: u64, length: u32, flags: u16, next: u16 };
const Available = extern struct { flags: u16, index: u16, ring: [QUEUE_SIZE]u16, used_event: u16 };
const UsedEntry = extern struct { id: u32, length: u32 };
const Used = extern struct { flags: u16, index: u16, ring: [QUEUE_SIZE]UsedEntry, available_event: u16 };

var descriptors: [QUEUE_SIZE]Descriptor align(4096) = undefined;
var available: Available align(4096) = undefined;
var used: Used align(4096) = undefined;

// ── GPU commands ───────────────────────────────────────────────────────────
const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
const CMD_SET_SCANOUT: u32 = 0x0103;
const CMD_RESOURCE_FLUSH: u32 = 0x0104;
const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
const RESPONSE_OK: u32 = 0x1100;
const FORMAT_BGRX: u32 = 2; // bytes blue, green, red, unused: 0x00RRGGBB as a number
const RESOURCE: u32 = 1;

const Header = extern struct { kind: u32, flags: u32 = 0, fence: u64 = 0, context: u32 = 0, padding: u32 = 0 };
const Rect = extern struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };
const Create2d = extern struct { header: Header, resource: u32, format: u32, width: u32, height: u32 };
const AttachBacking = extern struct { header: Header, resource: u32, entries: u32, address: u64, length: u32, padding: u32 = 0 };
const SetScanout = extern struct { header: Header, rect: Rect, scanout: u32, resource: u32 };
const Transfer = extern struct { header: Header, rect: Rect, offset: u64 = 0, resource: u32, padding: u32 = 0 };
const Flush = extern struct { header: Header, rect: Rect, resource: u32, padding: u32 = 0 };

var base: u64 = 0;
var width: u32 = 0;
var height: u32 = 0;
// Requests and answers live here, not on a stack: the host reads them by
// physical address.
var request: [64]u8 align(16) = undefined;
var response: Header align(16) = undefined;

fn reg(offset: u64) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn setQueueAddress(offset: u64, address: u64) void {
    const physical = cpu.phys(address);
    reg(offset).* = @truncate(physical);
    reg(offset + 4).* = @truncate(physical >> 32);
}

/// Is there a GPU behind the transport at this physical address?
pub fn probe(transport_physical: u64) bool {
    const at = cpu.virt(transport_physical);
    const r = struct {
        fn get(a: u64, offset: u64) u32 {
            return @as(*volatile u32, @ptrFromInt(a + offset)).*;
        }
    };
    return r.get(at, MAGIC) == MAGIC_VALUE and r.get(at, VERSION) == 2 and r.get(at, DEVICE_ID) == ID_GPU;
}

/// Send one command and wait for its answer. True if the GPU said OK.
fn command(comptime T: type, message: T) bool {
    @as(*T, @ptrCast(@alignCast(&request))).* = message;
    response = .{ .kind = 0 };
    descriptors[0] = .{ .address = cpu.phys(@intFromPtr(&request)), .length = @sizeOf(T), .flags = DESC_NEXT, .next = 1 };
    descriptors[1] = .{ .address = cpu.phys(@intFromPtr(&response)), .length = @sizeOf(Header), .flags = DESC_WRITE, .next = 0 };

    const available_index: *volatile u16 = &available.index;
    const used_index: *volatile u16 = &used.index;
    const before = used_index.*;
    available.ring[available_index.* % QUEUE_SIZE] = 0;
    asm volatile ("dmb ish");
    available_index.* +%= 1;
    asm volatile ("dmb ish");
    reg(QUEUE_NOTIFY).* = 0;

    const start = cpu.counter();
    while (used_index.* == before) {
        if (cpu.elapsedMicros(start) > 2_000_000) return false;
        cpu.relax();
    }
    asm volatile ("dmb ish");
    return @as(*volatile u32, &response.kind).* == RESPONSE_OK;
}

/// Set the GPU up to show the `w` by `h` picture at `pixels` (a kernel
/// address; one u32 a pixel).
pub fn init(transport_physical: u64, pixels: u64, w: u32, h: u32) bool {
    if (!probe(transport_physical)) return false;
    base = cpu.virt(transport_physical);
    width = w;
    height = h;

    reg(STATUS).* = 0; // reset
    reg(STATUS).* = STATUS_ACKNOWLEDGE;
    reg(STATUS).* = STATUS_ACKNOWLEDGE | STATUS_DRIVER;
    // The only feature taken: "this is a version 1 (modern) driver", bit 32.
    reg(DEVICE_FEATURES_SEL).* = 1;
    if (reg(DEVICE_FEATURES).* & 1 == 0) return false;
    reg(DRIVER_FEATURES_SEL).* = 0;
    reg(DRIVER_FEATURES).* = 0;
    reg(DRIVER_FEATURES_SEL).* = 1;
    reg(DRIVER_FEATURES).* = 1;
    reg(STATUS).* = STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK;
    if (reg(STATUS).* & STATUS_FEATURES_OK == 0) return false;

    // Queue 0 carries the commands.
    reg(QUEUE_SEL).* = 0;
    if (reg(QUEUE_NUM_MAX).* < QUEUE_SIZE) return false;
    @memset(@as([*]u8, @ptrCast(&descriptors))[0..@sizeOf(@TypeOf(descriptors))], 0);
    @memset(@as([*]u8, @ptrCast(&available))[0..@sizeOf(Available)], 0);
    @memset(@as([*]u8, @ptrCast(&used))[0..@sizeOf(Used)], 0);
    reg(QUEUE_NUM).* = QUEUE_SIZE;
    setQueueAddress(QUEUE_DESC, @intFromPtr(&descriptors));
    setQueueAddress(QUEUE_DRIVER, @intFromPtr(&available));
    setQueueAddress(QUEUE_DEVICE, @intFromPtr(&used));
    reg(QUEUE_READY).* = 1;
    reg(STATUS).* = STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK;

    if (!command(Create2d, .{ .header = .{ .kind = CMD_RESOURCE_CREATE_2D }, .resource = RESOURCE, .format = FORMAT_BGRX, .width = w, .height = h })) return false;
    if (!command(AttachBacking, .{ .header = .{ .kind = CMD_RESOURCE_ATTACH_BACKING }, .resource = RESOURCE, .entries = 1, .address = cpu.phys(pixels), .length = w * h * 4 })) return false;
    return command(SetScanout, .{ .header = .{ .kind = CMD_SET_SCANOUT }, .rect = .{ .width = w, .height = h }, .scanout = 0, .resource = RESOURCE });
}

/// Show the whole picture as it is now.
pub fn present() bool {
    if (base == 0) return false;
    const whole: Rect = .{ .width = width, .height = height };
    if (!command(Transfer, .{ .header = .{ .kind = CMD_TRANSFER_TO_HOST_2D }, .rect = whole, .resource = RESOURCE })) return false;
    return command(Flush, .{ .header = .{ .kind = CMD_RESOURCE_FLUSH }, .rect = whole, .resource = RESOURCE });
}
